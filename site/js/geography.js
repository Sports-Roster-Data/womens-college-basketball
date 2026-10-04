/* geography.js — five views of where players come from:
   1. US hometown choropleth (count ↔ per-1M-residents, season radio) + all-states table
   2. International players over time (count ↔ share of all players)
   3. Country treemap (USA excluded by default)
   4. Hometown hotbeds (top 25 US cities, distinct players ↔ player-seasons) + full city table
   5. In-state recruiting % by season and division (top/bottom 25)
   Views 1-4 take a Division dropdown (All / I / II / III) fed by the
   per-division aggregates in geography.json; the NAIA and blank-division
   buckets are not offered and appear only under All. Every view has a CSV
   download; every chart has a takeaway line. Chart instances are created once
   per view render; controls update via setOption. */
(function () {
  'use strict';
  var App = window.App;

  var geoTables = []; // Tabulator instances to destroy on route change
  var renderToken = 0; // aborts a superseded render's data fetch (fast re-navigation)

  function radios(ariaName, inputName, options, value, onch) {
    var row = App.h('div', { class: 'radio-row', role: 'radiogroup', 'aria-label': ariaName });
    options.forEach(function (o) {
      var input = App.h('input', {
        type: 'radio', name: inputName, value: o.value,
        onchange: function () { onch(o.value); }
      });
      input.checked = o.value === value;
      row.append(App.h('label', {}, input, o.label));
    });
    return App.h('div', { class: 'control' },
      App.h('span', { class: 'control-label', text: ariaName }), row);
  }

  function group(controls, card) {
    var g = App.h('div', { class: 'chart-group' });
    if (controls) g.append(App.h('div', { class: 'controls' }, controls));
    g.append(card);
    return g;
  }

  function chartSub(text) {
    return App.h('p', { class: 'chart-sub', text: text });
  }

  // Division dropdown shared by views 1-4. NAIA (35 roster rows) and the blank
  // "Unknown" bucket from the build are deliberately not offered here; both
  // appear only under All, matching the overall figures.
  function divOptions() {
    return [{ value: 'all', label: 'All' }].concat(
      App.meta.filter_options.division.filter(function (d) { return d === 'I' || d === 'II' || d === 'III'; })
        .map(function (d) { return { value: d, label: 'Division ' + d }; }));
  }
  function divSelect(value, onch) {
    return App.select({ label: 'Division', value: value, options: divOptions(), onchange: onch });
  }

  App.register('geography', {
    title: function () { return App.titled('Geography'); },
    cleanup: function () {
      geoTables.forEach(function (t) { try { t.destroy(); } catch (e) { /* gone */ } });
      geoTables = [];
    },
    render: function (sec) {
      sec.textContent = '';
      sec.append(App.loading());
      var token = ++renderToken;
      return Promise.all([
        App.getJSON('data/geography.json'),
        App.getJSON('data/us-states.json'),
        App.getObjects('data/teams.json'),
        App.getObjects('data/team_seasons.json')
      ]).then(function (res) {
        if (token !== renderToken) return;
        build(sec, res[0], res[1], res[2], res[3]);
      });
    }
  });

  function build(sec, geo, geojson, teamsList, teamSeasons) {
    echarts.registerMap('USA', geojson);
    var seasons = App.seasons;
    var lastSeason = seasons[seasons.length - 1];
    var statesMeta = App.meta.states;

    sec.textContent = '';
    sec.append(
      App.h('div', { class: 'page-head' },
        App.h('h1', { text: 'Geography' }),
        App.h('p', { class: 'lede',
          text: 'Where the players come from, using the cleaned hometown fields. Hometowns are parsed but not normalized, so city tabulations are best-effort.' })));

    /* ---------- 1. US choropleth + all-states table ---------- */

    var nameToCode = {};
    Object.keys(statesMeta).forEach(function (code) {
      nameToCode[statesMeta[code].name] = code;
    });
    var featureNames = {};
    geojson.features.forEach(function (f) { featureNames[f.properties.name] = true; });
    var unmapped = Object.keys(geo.state_season).filter(function (code) {
      return statesMeta[code] && !featureNames[statesMeta[code].name];
    });

    var mapState = { mode: 'percap', season: -1, division: 'all' }; // -1 = all seasons; per-capita is the default measure
    var mapEl = App.h('div', { class: 'chart', style: 'height:440px', role: 'img',
      'aria-label': 'Choropleth map of players by home state' });
    var mapTable = App.h('div', { class: 'table-wrap max-h' });
    var mapTakeaway = App.h('p', { class: 'takeaway' });
    var mapSub = chartSub('');
    var mapInst; // created after attach — ECharts measures the container at init

    function stateCount(code, seasonIdx, division) {
      var m = (division && division !== 'all') ? geo.state_season_division[division] : geo.state_season;
      var arr = m[code];
      if (!arr) return 0;
      if (seasonIdx < 0) return arr.reduce(function (a, b) { return a + b; }, 0);
      return arr[seasonIdx] || 0;
    }

    // Per 1M residents — NaN for codes with no population (AE), which sort
    // last and shade as no-data. Whatever the division, the denominator stays
    // the full-state population (Division I players per 1M residents).
    function statePercap(code, seasonIdx, division) {
      var pop = statesMeta[code] ? statesMeta[code].pop : null;
      return pop ? stateCount(code, seasonIdx, division) / pop * 1e6 : NaN;
    }

    // Sort by the shaded measure so the table twin always mirrors the map:
    // per 1M residents in percap mode (ties by count, then code), count in
    // count mode.
    function measureSort(a, b) {
      if (mapState.mode === 'percap') {
        var pa = statePercap(a, mapState.season, mapState.division);
        var pb = statePercap(b, mapState.season, mapState.division);
        if (isNaN(pa) !== isNaN(pb)) return isNaN(pa) ? 1 : -1;
        if (!isNaN(pa) && pa !== pb) return pb - pa;
      }
      return (stateCount(b, mapState.season, mapState.division) - stateCount(a, mapState.season, mapState.division)) ||
             (a < b ? -1 : a > b ? 1 : 0);
    }

    function mapUpdate() {
      mapSub.textContent = 'Players whose hometown has a US state, by state, ' +
        (mapState.division === 'all' ? 'all divisions' : 'Division ' + mapState.division) +
        (unmapped.length ? ' — * marks ' + unmapped.map(function (c) { return statesMeta[c].name; }).join(', ') +
          ', which are not drawn on the map' : '') + '.';
      var rows = geojson.features.map(function (f) {
        var code = nameToCode[f.properties.name];
        var count = code ? stateCount(code, mapState.season, mapState.division) : 0;
        var pop = code && statesMeta[code] ? statesMeta[code].pop : null;
        var v = (mapState.mode === 'percap')
          ? (pop ? Math.round(count / pop * 1e6 * 10) / 10 : NaN)
          : count;
        return { name: f.properties.name, value: v, count: count, code: code, pop: pop };
      });
      var vals = rows.filter(function (r) { return !isNaN(r.value); })
        .map(function (r) { return r.value; });
      var maxV = Math.max.apply(null, vals.concat([0]));

      mapInst.setOption({
        aria: { show: true },
        tooltip: {
          trigger: 'item',
          formatter: function (p) {
            var r = p.data || {};
            if (!r.code || isNaN(p.value)) return App.esc(p.name);
            var popTxt = r.pop ? ' · ' + Math.round(r.count / r.pop * 1e6 * 10) / 10 + ' per 1M residents' : '';
            return App.esc(p.name) + '<br/><strong>' + App.fmtNum(r.count) + '</strong> players' + popTxt;
          }
        },
        visualMap: {
          type: 'continuous', min: 0, max: maxV, left: 8, bottom: 8, itemWidth: 12,
          precision: mapState.mode === 'percap' ? 1 : 0,
          inRange: { color: App.seqRamp }, outOfRange: { color: App.noData },
          text: ['most', '0']
        },
        series: [{
          type: 'map', map: 'USA', data: rows, selectedMode: false,
          emphasis: { label: { show: true }, itemStyle: { areaColor: '#60a5fa' } }
        }]
      });

      // Table twin: every state/territory in the data, sorted by the shaded measure
      var allCodes = Object.keys(geo.state_season).sort(measureSort);
      mapTable.textContent = '';
      var tbody = App.h('tbody', {});
      allCodes.forEach(function (code) {
        var count = stateCount(code, mapState.season, mapState.division);
        var pop = statesMeta[code] ? statesMeta[code].pop : null;
        tbody.append(App.h('tr', {},
          App.h('td', { text: (statesMeta[code] ? statesMeta[code].name : code) +
            (unmapped.indexOf(code) >= 0 ? ' *' : '') }),
          App.h('td', { class: 'num', text: App.fmtNum(count) }),
          App.h('td', { class: 'num', text: pop ? Math.round(count / pop * 1e6 * 10) / 10 : '—' })));
      });
      mapTable.append(App.h('table', {},
        App.h('thead', {}, App.h('tr', {},
          App.h('th', { text: 'State' }), App.h('th', { text: 'Players' }),
          App.h('th', { text: 'Per 1M' }))), tbody));

      var leadCode = allCodes[0];
      var leadCount = stateCount(leadCode, mapState.season, mapState.division);
      var leadPc = statePercap(leadCode, mapState.season, mapState.division);
      var lead = (mapState.mode === 'percap' && !isNaN(leadPc))
        ? Math.round(leadPc * 10) / 10 + ' players per 1M residents (' + App.fmtNum(leadCount) + ' on rosters)'
        : App.fmtNum(leadCount) + ' players' +
          (isNaN(leadPc) ? '' : ' (' + Math.round(leadPc * 10) / 10 + ' per 1M residents)');
      mapTakeaway.textContent = (mapState.season < 0 ? 'Across all seasons, ' : 'In ' + seasons[mapState.season] + ', ') +
        (statesMeta[leadCode] ? statesMeta[leadCode].name : leadCode) + ' leads with ' + lead +
        '. Click a state to open its players in the latest season’s roster.';
    }

    sec.append(group(
      [
        divSelect(mapState.division, function (v) { mapState.division = v; mapUpdate(); }),
        radios('Measure', 'geo-map-measure', [{ value: 'count', label: 'Players' },
                                              { value: 'percap', label: 'Per 1M residents' }],
               mapState.mode, function (v) { mapState.mode = v; mapUpdate(); }),
        radios('Season', 'geo-map-season',
               [{ value: -1, label: 'All seasons' }].concat(
                 seasons.map(function (s, i) { return { value: i, label: s }; })),
               mapState.season, function (v) { mapState.season = +v; mapUpdate(); })
      ],
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Where US players come from' }),
        mapSub,
        App.h('div', { class: 'geo-grid' }, mapEl, mapTable),
        mapTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('states_players.csv', function () {
            return [['division', 'state', 'name', 'players', 'per_1m_residents']]
              .concat(Object.keys(geo.state_season).sort(measureSort).map(function (code) {
                var count = stateCount(code, mapState.season, mapState.division);
                var pop = statesMeta[code] ? statesMeta[code].pop : null;
                return [mapState.division === 'all' ? 'all' : mapState.division,
                        code, statesMeta[code] ? statesMeta[code].name : code, count,
                        pop ? Math.round(count / pop * 1e6 * 10) / 10 : null];
              }));
          })))));

    /* ---------- 2. International players over time ---------- */

    var intMode = 'count';
    var intDiv = 'all';
    var intlEl = App.h('div', { class: 'chart', style: 'height:400px', role: 'img',
      'aria-label': 'Line chart of international players over time' });
    var intlTakeaway = App.h('p', { class: 'takeaway' });
    var intlSub = chartSub('');
    var intlInst;

    // The active country matrix follows the Division dropdown: 'all' reads the
    // overall one (which also spans NAIA/Unknown), a division reads its own.
    function countryMatrix(div) {
      return (div && div !== 'all') ? geo.country_season_division[div] : geo.country_season;
    }
    function countryCount(c) {
      return (countryMatrix(intDiv)[c] || []).reduce(function (a, b) { return a + b; }, 0);
    }
    // Share-mode denominator: every rostered player in this division that season.
    function seasonTotal(i) {
      if (intDiv !== 'all') {
        var m = countryMatrix(intDiv);
        return Object.keys(m).reduce(function (a, c) { return a + m[c][i]; }, 0);
      }
      return geo.season_totals[i];
    }
    function top8Now() {
      return Object.keys(countryMatrix(intDiv)).filter(function (c) { return c !== 'USA'; })
        .sort(function (a, b) { return countryCount(b) - countryCount(a); }).slice(0, 8);
    }
    function allIntl(i) {
      var m = countryMatrix(intDiv);
      return Object.keys(m).filter(function (c) { return c !== 'USA'; })
        .reduce(function (a, c) { return a + m[c][i]; }, 0);
    }

    function intlUpdate() {
      var top8 = top8Now();
      intlSub.textContent = 'The eight most common home countries outside the US, by season' +
        (intDiv === 'all' ? '.' : ' — Division ' + intDiv + ' rosters.');
      var fmt = intMode === 'share'
        ? function (v) { return (v === null || v === undefined) ? '' : v + '%'; }
        : App.fmtNum;
      var series = top8.map(function (c, i) {
        return {
          name: c, type: 'line', symbolSize: 8,
          itemStyle: { color: App.palette[i], borderColor: '#fff', borderWidth: 2 },
          lineStyle: { width: 2, color: App.palette[i] },
          endLabel: i === 0 ? { show: true, formatter: '{c}', color: '#1c1917' } : { show: false },
          data: (countryMatrix(intDiv)[c] || []).map(function (n, i) {
            return intMode === 'share' ? Math.round(n / seasonTotal(i) * 1000) / 10 : n;
          })
        };
      });
      // No All-international line: the total's scale flattens the individual
      // countries; the takeaway cites the totals instead.
      intlInst.setOption({
        aria: { show: true },
        legend: { top: 0, type: 'scroll' },
        tooltip: {
          trigger: 'axis',
          formatter: function (ps) { return App.tip(ps[0].axisValue, ps, fmt); }
        },
        grid: { left: 56, right: 48, top: 36, bottom: 30 },
        xAxis: { type: 'category', data: seasons, boundaryGap: false },
        yAxis: { type: 'value', name: intMode === 'share'
          ? (intDiv === 'all' ? '% of all players' : '% of Division ' + intDiv + ' players') : 'players' },
        series: series
      }, true);

      var all = seasons.map(function (s, i) {
        return intMode === 'share' ? Math.round(allIntl(i) / seasonTotal(i) * 1000) / 10 : allIntl(i);
      });
      intlTakeaway.textContent = 'International players ' +
        (intMode === 'share'
          ? 'rose from ' + all[0] + '% to ' + all[all.length - 1] + '% of ' +
            (intDiv === 'all' ? 'all rostered players.' : 'Division ' + intDiv + ' rostered players.')
          : 'grew from ' + App.fmtNum(all[0]) + ' in ' + seasons[0] + ' to ' + App.fmtNum(all[all.length - 1]) +
            ' in ' + lastSeason + '.') +
        ' ' + top8[0] + ' leads countries' + (intDiv === 'all' ? '.' : ' in Division ' + intDiv + '.');
    }

    sec.append(group(
      [radios('Measure', 'geo-intl-measure', [{ value: 'count', label: 'Players' },
                                              { value: 'share', label: 'Share of all players' }],
              intMode, function (v) { intMode = v; intlUpdate(); }),
       divSelect(intDiv, function (v) { intDiv = v; intlUpdate(); })],
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'International players over time' }),
        intlSub,
        intlEl,
        intlTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('international_by_season.csv', function () {
            var top8 = top8Now(); // freshly derived so the CSV matches what's on screen
            return [['division', 'season'].concat(top8).concat(['all_international'])]
              .concat(seasons.map(function (s, i) {
                return [intDiv === 'all' ? 'all' : intDiv, s]
                  .concat(top8.map(function (c) { return countryMatrix(intDiv)[c][i]; }))
                  .concat([allIntl(i)]);
              }));
          })))));

    /* ---------- 3. Country treemap ---------- */

    var inclUSA = false;
    var treeDiv = 'all';
    var treeEl = App.h('div', { class: 'chart', style: 'height:420px', role: 'img',
      'aria-label': 'Treemap of players by country' });
    var treeTakeaway = App.h('p', { class: 'takeaway' });
    var treeSub = chartSub('');
    var treeInst;

    function treeUpdate() {
      var m = countryMatrix(treeDiv); // helper defined with view 2
      var divTxt = treeDiv === 'all' ? '' : ' — Division ' + treeDiv + ' rosters';
      treeSub.textContent = 'Tile area is player-seasons across all seasons' + divTxt +
        '; darker blue means more. Small tiles are unlabeled — hover or use the CSV.';
      var data = Object.keys(m).filter(function (c) { return inclUSA || c !== 'USA'; })
        .map(function (c) {
          return { name: c, value: (m[c] || []).reduce(function (a, b) { return a + b; }, 0) };
        })
        .sort(function (a, b) { return b.value - a.value; });
      var grand = data.reduce(function (a, d) { return a + d.value; }, 0);
      var maxV = data[0].value;

      // Label color by fill luminance: white text on the two darkest ramp steps only
      data.forEach(function (d) {
        var step = maxV > 0 ? Math.min(5, Math.floor(d.value / maxV * 6)) : 0;
        d.label = { color: step >= 4 ? '#ffffff' : '#1c1917' };
      });

      treeInst.setOption({
        aria: { show: true },
        tooltip: {
          trigger: 'item',
          formatter: function (p) {
            return App.esc(p.name) + '<br/><strong>' + App.fmtNum(p.value) + '</strong> player-seasons (' +
              (100 * p.value / grand).toFixed(1) + '%)';
          }
        },
        visualMap: {
          type: 'continuous', min: 0, max: maxV, left: 8, bottom: 8, itemWidth: 12,
          inRange: { color: App.seqRamp }, outOfRange: { color: App.noData }, text: ['most', '0']
        },
        series: [{
          type: 'treemap', data: data, roam: false, nodeClick: false,
          breadcrumb: { show: false },
          itemStyle: { borderColor: '#fff', borderWidth: 2, gapWidth: 2 },
          label: {
            show: true, fontSize: 11, lineHeight: 15, overflow: 'truncate',
            formatter: function (p) {
              if (p.value < grand * 0.005) return '';          // too small to label
              return p.value >= grand * 0.01 ? p.name + '\n' + App.fmtNum(p.value) : p.name;
            }
          },
          upperLabel: { show: false }
        }]
      }, true);

      var lead = data[0];
      treeTakeaway.textContent = (inclUSA ? 'Including the US, ' : 'Excluding the US, ') + lead.name +
        ' leads' + (treeDiv === 'all' ? '' : ' in Division ' + treeDiv) + ' with ' + App.fmtNum(lead.value) +
        ' player-seasons' +
        (data.length > 1 && !inclUSA ? ', followed by ' + data[1].name + ' (' + App.fmtNum(data[1].value) + ')' : '') +
        '. Click a tile to open its players in the latest season’s roster.';
    }

    var usaToggle = App.h('input', {
      type: 'checkbox', id: 'usa-toggle',
      onchange: function (e) { inclUSA = e.target.checked; treeUpdate(); }
    });
    sec.append(group(
      [App.h('div', { class: 'control' },
         App.h('span', { class: 'control-label', text: 'United States' }),
         App.h('label', { class: 'radio-row' }, usaToggle, ' include')),
       divSelect(treeDiv, function (v) { treeDiv = v; treeUpdate(); })],
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Where international players come from' }),
        treeSub,
        treeEl,
        treeTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('countries_players.csv', function () {
            var m = countryMatrix(treeDiv);
            return [['division', 'country', 'player_seasons']]
              .concat(Object.keys(m)
                .map(function (c) {
                  return [treeDiv === 'all' ? 'all' : treeDiv, c,
                          (m[c] || []).reduce(function (a, b) { return a + b; }, 0)];
                })
                .sort(function (a, b) { return b[2] - a[2]; }));
          })))));

    /* ---------- 4. Hometown hotbeds + full city table ---------- */

    var hbMode = 'players';
    var hbDiv = 'all';
    var hbEl = App.h('div', { class: 'chart', style: 'height:640px', role: 'img',
      'aria-label': 'Bar chart of the top US hometowns' });
    var hbTakeaway = App.h('p', { class: 'takeaway' });
    var hbSub = chartSub('');
    var hbInst;
    var cityTable; // full city table (below), created after attach

    // Per-division city lists come pre-thresholded by the build (>= 10 distinct
    // players within that division), so a city can appear in one division's
    // list but not another's.
    function citiesNow() {
      return (hbDiv !== 'all') ? (geo.cities_division[hbDiv] || []) : geo.cities;
    }
    function cityRows() {
      return citiesNow().map(function (c) {
        return { key: c[0] + '|' + c[1], city: c[0], state: c[1], players: c[2], rows: c[3] };
      });
    }
    function refreshCityTable() {
      cityCountSub.textContent = citiesNow().length + ' US cities' +
        (hbDiv === 'all' ? '' : ' with 10+ Division ' + hbDiv + ' players') +
        ', best-effort parsed from hometown strings.';
      if (cityTable) cityTable.setData(cityRows());
    }

    function hbUpdate() {
      var list = citiesNow().slice().sort(function (a, b) {
        return hbMode === 'rows' ? b[3] - a[3] : b[2] - a[2];
      }).slice(0, 25);
      var labelKey = hbMode === 'rows' ? 3 : 2;
      hbSub.textContent = 'US cities that have sent at least 10 distinct players to ' +
        (hbDiv === 'all' ? 'these rosters' : 'Division ' + hbDiv + ' rosters (a player who crossed divisions counts in both)') +
        ', top 25.';

      hbInst.setOption({
        aria: { show: true },
        tooltip: {
          trigger: 'item',
          formatter: function (p) {
            var c = p.data && p.data.raw;
            if (!c) return '';
            return App.esc(c[0] + ', ' + c[1]) + '<br/><strong>' + App.fmtNum(c[labelKey]) + '</strong> ' +
              (hbMode === 'rows' ? 'player-seasons (' + App.fmtNum(c[2]) + ' distinct players)'
                                : 'distinct players (' + App.fmtNum(c[3]) + ' player-seasons)');
          }
        },
        grid: { left: 130, right: 60, top: 10, bottom: 28 },
        xAxis: { type: 'value', name: hbMode === 'rows' ? 'player-seasons' : 'distinct players' },
        yAxis: {
          type: 'category', inverse: true,
          data: list.map(function (c) { return c[0] + ', ' + c[1]; }),
          axisLabel: { width: 120, overflow: 'truncate' }
        },
        series: [{
          type: 'bar', barWidth: 16,
          itemStyle: { color: App.palette[0], borderRadius: [0, 4, 4, 0] },
          label: { show: true, position: 'right', color: '#78716c' },
          data: list.map(function (c) { return { value: c[labelKey], raw: c }; })
        }]
      }, true);

      hbTakeaway.textContent = list[0][0] + ' leads with ' + App.fmtNum(list[0][labelKey]) + ' ' +
        (hbMode === 'rows' ? 'player-seasons' : 'distinct players') +
        ' across ' + (hbDiv === 'all' ? 'these rosters' : 'Division ' + hbDiv + ' rosters') +
        '. Click a bar to open that hometown in the latest season’s roster.';
    }

    var cityCountSub = chartSub('');
    sec.append(group(
      [radios('Measure', 'geo-hb-measure', [{ value: 'players', label: 'Distinct players' },
                                            { value: 'rows', label: 'Player-seasons' }],
              hbMode, function (v) { hbMode = v; hbUpdate(); }),
       divSelect(hbDiv, function (v) { hbDiv = v; hbUpdate(); refreshCityTable(); })],
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Hometown hotbeds' }),
        hbSub,
        hbEl,
        hbTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('cities_players.csv', function () {
            var dv = hbDiv === 'all' ? 'all' : hbDiv;
            return [['division', 'city', 'state', 'distinct_players', 'player_seasons']]
              .concat(citiesNow().map(function (c) { return [dv].concat(c); }));
          })))));

    var cityTableEl = App.h('div', { id: 'city-table' });
    sec.append(App.h('section', { class: 'card' },
      App.h('h2', { style: 'font-size:15px;font-weight:600;margin:0 0 8px', text: 'Every city with 10+ players' }),
      cityCountSub,
      cityTableEl,
      App.h('div', { class: 'card-foot' },
        App.csvBtn('cities_all.csv', function () {
          var dv = hbDiv === 'all' ? 'all' : hbDiv;
          return [['division', 'city', 'state', 'distinct_players', 'player_seasons']]
            .concat(citiesNow().map(function (c) { return [dv].concat(c); }));
        }))));

    /* ---------- 5. In-state recruiting % ---------- */

    var teamById = {};
    teamsList.forEach(function (t) { teamById[t.id] = t; });
    var inSel = { season: seasons.length - 1, division: 'all' };
    var topEl = App.h('div', { class: 'chart', style: 'height:560px', role: 'img',
      'aria-label': 'Bar chart of teams with the highest share of in-state players' });
    var botEl = App.h('div', { class: 'chart', style: 'height:560px', role: 'img',
      'aria-label': 'Bar chart of teams with the lowest share of in-state players' });
    var inTakeaway = App.h('p', { class: 'takeaway' });
    var currentRows = [];
    var topInst, botInst;

    function barOption(rows) {
      return {
        aria: { show: true },
        tooltip: {
          trigger: 'item',
          formatter: function (p) {
            var d = p.data && p.data.raw;
            if (!d) return '';
            return App.esc(d.team) + '<br/><strong>' + App.fmtPct(d.pct) + '</strong> in-state (' +
              d.in_state + ' of ' + d.us + ' US players)';
          }
        },
        grid: { left: 130, right: 56, top: 10, bottom: 28 },
        xAxis: { type: 'value', max: 1,
                 axisLabel: { formatter: function (v) { return Math.round(v * 100) + '%'; } } },
        yAxis: { type: 'category', inverse: true,
                 data: rows.map(function (d) { return d.team; }),
                 axisLabel: { width: 120, overflow: 'truncate' } },
        series: [{
          type: 'bar', barWidth: 16,
          itemStyle: { color: App.palette[0], borderRadius: [0, 4, 4, 0] },
          label: { show: true, position: 'right', color: '#78716c',
                   formatter: function (p) { return App.fmtPct(p.data.raw.pct, 0); } },
          data: rows.map(function (d) { return { value: d.pct, raw: d }; })
        }]
      };
    }

    function inUpdate() {
      var list = [];
      teamSeasons.forEach(function (r) {
        if (r.season_idx !== inSel.season) return;
        var t = teamById[r.ncaa_id];
        if (!t) return;
        if (inSel.division !== 'all' && t.division !== inSel.division) return;
        if (!r.us_players || r.us_players < 5 || r.in_state === null) return;
        list.push({ team: t.team, id: t.id, pct: r.in_state / r.us_players,
                    in_state: r.in_state, us: r.us_players });
      });
      currentRows = list.sort(function (a, b) { return b.pct - a.pct; });
      topInst.setOption(barOption(currentRows.slice(0, 25)), true);
      botInst.setOption(barOption(currentRows.slice(-25).reverse()), true);

      var mean = currentRows.reduce(function (a, d) { return a + d.pct; }, 0) / (currentRows.length || 1);
      inTakeaway.textContent = 'In ' + seasons[inSel.season] +
        (inSel.division === 'all' ? '' : ', Division ' + inSel.division) + ', teams drew on average ' +
        App.fmtPct(mean) + ' of their US players from their own state (teams with at least 5 US players). ' +
        'Click a bar to open the team.';
    }

    sec.append(group(
      [
        App.select({
          label: 'Season', value: String(inSel.season),
          options: seasons.map(function (s, i) { return { value: String(i), label: s }; }),
          onchange: function (v) { inSel.season = +v; inUpdate(); }
        }),
        App.select({
          label: 'Division', value: inSel.division,
          options: [{ value: 'all', label: 'All' }].concat(
            App.meta.filter_options.division.filter(function (d) { return d !== 'Unknown'; })
              .map(function (d) {
                return { value: d, label: d === 'I' ? 'Division I' : d === 'II' ? 'Division II' : d === 'III' ? 'Division III' : d };
              })),
          onchange: function (v) { inSel.division = v; inUpdate(); }
        })
      ],
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'In-state recruiting' }),
        chartSub('Share of each team’s US players whose home state matches the team’s state — the 25 highest and 25 lowest, among teams with at least 5 US players.'),
        App.h('div', { class: 'two-col' },
          App.h('div', {},
            App.h('h3', { style: 'font-size:13px;font-weight:600;margin:0 0 4px', text: 'Most home-state players' }), topEl),
          App.h('div', {},
            App.h('h3', { style: 'font-size:13px;font-weight:600;margin:0 0 4px', text: 'Fewest home-state players' }), botEl)),
        inTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('in_state_recruiting.csv', function () {
            return [['season', 'team', 'ncaa_id', 'us_players', 'in_state', 'in_state_pct']]
              .concat(currentRows.map(function (d) {
                return [seasons[inSel.season], d.team, d.id, d.us, d.in_state, Math.round(d.pct * 1000) / 10];
              }));
          })))));

    /* ---------- initial renders ---------- */

    // All cards are attached by this point, so the chart instances finally
    // measure a real container — ECharts on a detached element measures 0×0,
    // which breaks the geo layouts outright.
    mapInst = App.chart(mapEl);
    mapInst.on('click', function (p) {
      var code = p.data && p.data.code;
      if (code) location.hash = '#/roster/' + lastSeason + '?state=' + code;
    });
    intlInst = App.chart(intlEl);
    treeInst = App.chart(treeEl);
    treeInst.on('click', function (p) {
      if (p.name) location.hash = '#/roster/' + lastSeason + '?country=' + encodeURIComponent(p.name);
    });
    hbInst = App.chart(hbEl);
    hbInst.on('click', function (p) {
      if (p.data && p.data.raw) {
        location.hash = '#/roster/' + lastSeason + '?hometown=' + encodeURIComponent(p.data.raw[0]);
      }
    });
    topInst = App.chart(topEl);
    botInst = App.chart(botEl);
    topInst.on('click', function (p) { if (p.data && p.data.raw) location.hash = '#/team/' + p.data.raw.id; });
    botInst.on('click', function (p) { if (p.data && p.data.raw) location.hash = '#/team/' + p.data.raw.id; });

    mapUpdate();
    intlUpdate();
    treeUpdate();
    hbUpdate();
    inUpdate();

    var cityTable = new Tabulator(cityTableEl, {
      index: 'key',
      columns: [
        { title: 'City', field: 'city', minWidth: 140, maxWidth: 260, headerFilter: 'input', headerFilterPlaceholder: 'filter' },
        { title: 'State', field: 'state', minWidth: 70, maxWidth: 90, headerFilter: 'input', headerFilterPlaceholder: 'filter' },
        { title: 'Distinct players', field: 'players', minWidth: 140, sorter: 'number', hozAlign: 'right' },
        { title: 'Player-seasons', field: 'rows', minWidth: 130, sorter: 'number', hozAlign: 'right' }
      ],
      layout: 'fitDataStretch',
      height: 420,
      selectableRows: false,
      placeholder: 'No cities match.',
      initialSort: [{ column: 'players', dir: 'desc' }]
    });
    geoTables.push(cityTable);
    refreshCityTable(); // fills the count line + data now that the table exists
  }
})();