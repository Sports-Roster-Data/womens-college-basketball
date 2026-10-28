/* roster.js — Roster Explorer (single-season Tabulator grid), cross-year
   player cards, and team pages. Every filtered explorer view is a permalink:
   filters are written into the hash query (App.replaceQuery) and restored on
   render, so a URL like #/roster/2024-25?state=TX&position=GUADER reproduces. */
(function () {
  'use strict';
  var App = window.App;

  /* ---------- shared helpers ---------- */

  function notFound(sec, msg) {
    sec.textContent = '';
    sec.append(App.h('div', { class: 'card' },
      App.h('h1', { text: 'Not found' }),
      App.h('p', { text: msg }),
      App.h('p', {}, 'Try the ',
        App.h('a', { href: '#/roster' }, 'roster explorer'),
        ', or search by name in the box at the top of the page.')));
  }

  function orDash(v) { return (v === null || v === undefined) ? '—' : v; }

  /* ---------- Roster Explorer ---------- */

  // Hash aliases → Tabulator fields. The alias form is the permalink contract
  // (#/roster/2024-25?state=TX), so geography/team drills stay short.
  var ALIASES = {
    name: 'name', team: 'team', jersey: 'jersey',
    position: 'position_clean', year: 'year_clean',
    state: 'state_clean', country: 'country_clean',
    hometown: 'hometown_clean', previous: 'previous_school_clean',
    hs: 'hs_clean', conference: 'conference', division: 'division'
  };
  var ALIAS_OF_FIELD = {};
  Object.keys(ALIASES).forEach(function (k) { ALIAS_OF_FIELD[ALIASES[k]] = k; });

  var UNKNOWN = '__unknown__'; // synthetic select option for blank values

  // Header-filter match function. Tabulator calls headerFilterFunc as
  // (term, cellValue, rowData) — term is the filter box, cellValue the row's
  // field — so exact match ("I" must not match "II") with an "Unknown"
  // option that catches blanks and literal Unknown values.
  function exactOrUnknown(term, cellValue, rowData) {
    var t = (term === null || term === undefined) ? '' : String(term);
    if (!t) return true;
    var v = (cellValue === null || cellValue === undefined) ? '' : String(cellValue);
    if (t === UNKNOWN) return v === '' || v === 'Unknown';
    return v === t;
  }

  // Tabulator 6.3.1 ships no "select" editor (its replacement, "list", is an
  // autocomplete-style input), so the dropdown filters are a hand-built
  // native <select> following the editor contract the input editor uses:
  // build the element, seed it with cell.getValue() (the current term — the
  // permalink), and call success(value) on change, cancel() otherwise.
  function selectOptions(list) {
    var values = list.slice();
    if (values[values.length - 1] === 'Unknown') values.pop();
    var opts = [{ value: '', label: 'All' }];
    values.forEach(function (v) { opts.push({ value: v, label: v }); });
    opts.push({ value: UNKNOWN, label: 'Unknown' });
    return opts;
  }

  function selectHeaderFilter(options, ariaLabel) {
    return function (cell, onRendered, success, cancel) {
      var sel = document.createElement('select');
      sel.setAttribute('aria-label', ariaLabel);
      sel.style.padding = '4px';
      sel.style.width = '100%';
      sel.style.boxSizing = 'border-box';
      options.forEach(function (o) {
        var el = document.createElement('option');
        el.value = o.value;
        el.textContent = o.label;
        sel.append(el);
      });
      var init = cell.getValue();
      init = (init === null || init === undefined) ? '' : String(init);
      if (init && !options.some(function (o) { return o.value === init; })) {
        // a term from a hand-edited permalink that is not one of our options:
        // show it rather than masking an active filter as "All"
        var raw = document.createElement('option');
        raw.value = init;
        raw.textContent = init;
        sel.append(raw);
      }
      sel.value = init;
      function apply() {
        if (sel.value !== init) { success(sel.value); init = sel.value; }
        else cancel();
      }
      sel.addEventListener('change', apply);
      sel.addEventListener('blur', apply);
      sel.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') apply();
        else if (e.key === 'Escape') cancel();
      });
      return sel;
    };
  }

  function playerLink(cell) {
    var d = cell.getData();
    if (!d.wbb_id) return d.name || '';
    return App.h('a', { href: '#/player/' + d.wbb_id, text: d.name || d.wbb_id });
  }

  function teamLink(cell) {
    var d = cell.getData();
    if (!d.ncaa_id) return d.team || '';
    return App.h('a', { href: '#/team/' + d.ncaa_id, text: d.team || d.ncaa_id });
  }

  function rsChip(cell) {
    return cell.getValue() ? 'RS' : '';
  }

  function heightFmt(cell) {
    return App.fmtHeight(cell.getValue());
  }

  function urlLink(cell) {
    var v = cell.getValue();
    if (!v) return '';
    return App.h('a', { href: v, target: '_blank', rel: 'noopener', text: 'roster ↗' });
  }

  function buildColumns() {
    var fo = App.meta.filter_options;
    // titleDownload puts the machine-readable field names in the exported CSV,
    // matching the repo's season files and the About data dictionary.
    var text = function (field, title) {
      return { title: title, field: field, titleDownload: field,
               headerFilter: 'input', headerFilterPlaceholder: 'filter',
               minWidth: 70, maxWidth: 320 };
    };
    var select = function (field, title, list) {
      return { title: title, field: field, titleDownload: field,
               headerFilter: selectHeaderFilter(selectOptions(list), title),
               headerFilterFunc: exactOrUnknown, minWidth: 90, maxWidth: 220 };
    };
    return [
      Object.assign(text('name', 'Name'), { minWidth: 140, maxWidth: 220, formatter: playerLink }),
      Object.assign(text('team', 'Team'), { minWidth: 130, maxWidth: 220, formatter: teamLink }),
      Object.assign(text('jersey', 'Jersey'), { minWidth: 70, maxWidth: 90 }),
      select('position_clean', 'Position', fo.position),
      select('year_clean', 'Class', fo.year),
      { title: 'RS', field: 'redshirt', titleDownload: 'redshirt',
        minWidth: 60, maxWidth: 60, hozAlign: 'center', formatter: rsChip },
      { title: 'Ht', field: 'total_inches', titleDownload: 'total_inches',
        minWidth: 60, maxWidth: 70, hozAlign: 'center',
        sorter: 'number', formatter: heightFmt },
      text('hometown_clean', 'Hometown'),
      select('state_clean', 'State', fo.state),
      select('country_clean', 'Country', fo.country),
      text('hs_clean', 'High school'),
      text('previous_school_clean', 'Previous school'),
      select('conference', 'Conference', fo.conference),
      select('division', 'Division', fo.division),
      Object.assign(text('primary_position', 'Primary'), { minWidth: 90, maxWidth: 120 }),
      Object.assign(text('wbb_id', 'ID'), { minWidth: 100, maxWidth: 110 }),
      Object.assign(text('ncaa_id', 'Team ID'), { minWidth: 80, maxWidth: 90 }),
      Object.assign(text('url', 'Roster'),
        { minWidth: 80, maxWidth: 90, formatter: urlLink, headerSort: false })
    ];
  }

  var rosterTable = null;   // live Tabulator instance, or null
  var explorerState = null; // { q, ncaa } — quick-search + team-drill filters

  function applyCustom(state) {
    var t = rosterTable;
    if (!t) return;
    if (!state.q && !state.ncaa) { t.clearFilter(); return; }
    t.setFilter(function (data) {
      if (state.ncaa && String(data.ncaa_id) !== state.ncaa) return false;
      if (state.q) {
        var q = state.q.toLowerCase();
        return String(data.name || '').toLowerCase().indexOf(q) >= 0 ||
               String(data.team || '').toLowerCase().indexOf(q) >= 0 ||
               String(data.hometown_clean || '').toLowerCase().indexOf(q) >= 0;
      }
      return true;
    });
  }

  function serializeFilters(state) {
    if (!rosterTable) return;
    var q = {};
    if (state.q) q.q = state.q;
    if (state.ncaa) q.ncaa_id = state.ncaa;
    rosterTable.getHeaderFilters().forEach(function (f) {
      var alias = ALIAS_OF_FIELD[f.field];
      if (alias && f.value) q[alias] = f.value;
    });
    App.replaceQuery(q);
  }

  App.register('roster', {
    title: function (params) {
      var s = params[0] || App.seasons[App.seasons.length - 1];
      return App.titled(App.seasons.indexOf(s) >= 0 ? 'Rosters ' + s : 'Roster explorer');
    },
    cleanup: function () {
      if (rosterTable) { rosterTable.destroy(); rosterTable = null; }
    },
    render: function (sec, params, query) {
      if (rosterTable) { rosterTable.destroy(); rosterTable = null; }
      var seasons = App.seasons;
      var season = (params[0] && seasons.indexOf(params[0]) >= 0)
        ? params[0] : seasons[seasons.length - 1];
      if (params[0] && params[0] !== season) {
        // unknown season in the URL → rewrite to the default, keeping filters
        var qs = Object.keys(query)
          .map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(query[k]); })
          .join('&');
        location.replace('#/roster/' + season + (qs ? '?' + qs : ''));
        return Promise.resolve();
      }

      sec.textContent = '';
      var qTimer = null;
      var qInput = App.h('input', {
        type: 'search', value: query.q || '', 'aria-label': 'Quick search',
        placeholder: 'name, team or hometown…',
        oninput: function (e) {
          if (!explorerState) return;
          var v = e.target.value.trim();
          clearTimeout(qTimer);
          qTimer = setTimeout(function () {
            explorerState.q = v;
            applyCustom(explorerState);
          }, 250);
        }
      });
      var csvBtn = App.h('button', {
        class: 'btn btn-primary', type: 'button',
        onclick: function () {
          if (!rosterTable) return;
          var state = explorerState || {};
          var filtered = rosterTable.getHeaderFilters().length > 0 || state.q || state.ncaa;
          rosterTable.download('csv',
            'wbb_rosters_' + season.replace(/-/g, '_') + (filtered ? '_filtered' : '') + '.csv',
            {}, 'active');
        }
      }, 'Download CSV');

      sec.append(
        App.h('div', { class: 'page-head' },
          App.h('h1', { text: 'Roster explorer' }),
          App.h('p', { class: 'lede',
            text: 'Every player in ' + season + ' (' + App.fmtNum(App.meta.season_rows[seasons.indexOf(season)]) +
                  ' rows). Filter any column, then download exactly what you filtered as CSV.' })),
        App.h('div', { class: 'controls' },
          App.select({
            label: 'Season', value: season,
            options: seasons.map(function (s) { return { value: s, label: s }; }),
            onchange: function (next) {
              var raw = location.hash.replace(/^#/, '');
              var qs = raw.indexOf('?') >= 0 ? raw.slice(raw.indexOf('?') + 1) : '';
              location.hash = '#/roster/' + next + (qs ? '?' + qs : '');
            }
          }),
          App.h('label', { class: 'control' },
            App.h('span', { class: 'control-label', text: 'Quick search' }), qInput),
          csvBtn),
        App.h('p', { class: 'count-line', text: 'Loading ' + season + ' rosters…' }),
        App.h('div', { id: 'roster-table' }),
        App.h('p', { class: 'takeaway' }, 'RS marks a redshirt. Column meanings and caveats are in the ',
          App.h('a', { href: '#/about' }, 'data dictionary'), '.'));

      var count = sec.querySelector('.count-line');
      var tableEl = sec.querySelector('#roster-table');

      return App.getObjects('data/seasons/' + season + '.json').then(function (rows) {
        var state = { q: (query.q || '').trim(), ncaa: query.ncaa_id ? String(query.ncaa_id) : '' };
        explorerState = state;
        rows = rows.slice().sort(function (a, b) {
          return (a.team || '').localeCompare(b.team || '') ||
                 (a.name || '').localeCompare(b.name || '');
        });
        var total = rows.length;
        var restoring = true;

        rosterTable = new Tabulator(tableEl, {
          data: rows,
          index: 'wbb_id',
          columns: buildColumns(),
          layout: 'fitDataStretch',
          height: '65vh',
          selectableRows: false,
          placeholder: 'No rows match these filters.'
        });

        rosterTable.on('dataFiltered', function (filters, filtered) {
          if (restoring) return;
          count.textContent = App.fmtNum(filtered.length) + ' of ' + App.fmtNum(total) + ' rows';
          serializeFilters(state);
        });

        rosterTable.on('tableBuilt', function () {
          Object.keys(ALIASES).forEach(function (alias) {
            if (query[alias]) rosterTable.setHeaderFilterValue(ALIASES[alias], query[alias]);
          });
          applyCustom(state);
          restoring = false;
          count.textContent = App.fmtNum(rosterTable.getData('active').length) +
            ' of ' + App.fmtNum(total) + ' rows';
          serializeFilters(state);
        });
      });
    }
  });

  /* ---------- Player card ---------- */

  function confBadge(conf) {
    if (conf === 'high') return App.h('span', { class: 'badge', text: 'ID match: high confidence' });
    if (conf === 'medium') return App.h('span', { class: 'badge', text: 'ID match: medium confidence' });
    return App.h('span', { class: 'badge muted-badge', text: 'single-season record' });
  }

  function copyLinkBtn() {
    var btn = App.h('button', {
      class: 'btn btn-sm', type: 'button',
      onclick: function () {
        var url = location.href;
        var done = function () {
          btn.textContent = 'Link copied ✓';
          setTimeout(function () { btn.textContent = 'Copy link'; }, 2000);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(url).then(done, done);
        } else {
          var ta = document.createElement('textarea');
          ta.value = url;
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand('copy'); } catch (e) { /* clipboard unavailable */ }
          ta.remove();
          done();
        }
      }
    }, 'Copy link');
    return btn;
  }

  App.register('player', {
    title: function () { return App.titled('Player'); },
    render: function (sec, params) {
      sec.textContent = '';
      var id = params[0] || '';
      if (!/^wbb-\d{6}$/.test(id)) return Promise.resolve(notFound(sec, 'That link has no player id.'));
      var note = App.loading();
      sec.append(note);
      return App.getJSON('data/cards/' + id.slice(0, 7) + '.json').then(function (shard) {
        note.remove();
        var card = shard[id];
        if (!card) {
          notFound(sec, 'No player with id ' + id + ' — check the id, or search by name at the top of the page.');
          return;
        }
        document.title = App.titled(card.name);
        var seasons = card.seasons.slice().sort(function (a, b) { return a[0] - b[0]; });
        var teamIds = {};
        seasons.forEach(function (s) { teamIds[s[1]] = true; });
        var nTeams = Object.keys(teamIds).length;

        var facts = App.h('dl', { class: 'facts' });
        var fact = function (label, value, plain) {
          facts.append(App.h('div', {},
            App.h('dt', { text: label }),
            App.h('dd', { class: plain ? 'plain' : '', text: orDash(value) })));
        };
        fact('Position', card.pos);
        fact('Height', card.ht ? App.fmtHeight(card.ht) : null);
        fact('Hometown', card.home);
        if (card.co && card.co !== 'USA') fact('Country', card.co);
        fact('High school', card.hs, true);

        var timeline = App.h('ul', { class: 'timeline' });
        seasons.forEach(function (s) {
          // s = [season_idx, ncaa_id, team, year_clean, redshirt, url]
          var metaKids = [orDash(s[3])];
          if (s[4]) {
            metaKids.push(' ');
            metaKids.push(App.h('span', { class: 'chip', text: 'RS' }));
          }
          if (s[5]) {
            metaKids.push(' ');
            metaKids.push(App.h('a', { href: s[5], target: '_blank', rel: 'noopener', text: 'roster ↗' }));
          }
          timeline.append(App.h('li', {},
            App.h('span', { class: 'tl-season', text: App.seasons[s[0]] }),
            App.h('span', { class: 'tl-team' },
              s[1] ? App.h('a', { href: '#/team/' + s[1], text: s[2] }) : (s[2] || '—')),
            App.h('span', { class: 'tl-meta' }, metaKids)));
        });

        sec.append(
          App.h('div', { class: 'page-head detail-head' },
            App.h('h1', { text: card.name }),
            confBadge(card.conf),
            copyLinkBtn()),
          App.h('div', { class: 'card' },
            App.h('p', { class: 'count-line' },
              seasons.length + (seasons.length === 1 ? ' season' : ' seasons') + ', ' +
              nTeams + (nTeams === 1 ? ' team' : ' teams') + ' · ' +
              App.seasonSpan(seasons[0][0], seasons[seasons.length - 1][0])),
            facts),
          App.h('div', { class: 'card' },
            App.h('h2', { style: 'font-size:15px;font-weight:600;margin:0 0 8px', text: 'Season by season' }),
            timeline),
          App.h('div', { class: 'card-foot' },
            App.csvBtn(id + '_seasons.csv', function () {
              return [['season', 'team', 'ncaa_id', 'year_clean', 'redshirt', 'url']]
                .concat(seasons.map(function (s) {
                  return [App.seasons[s[0]], s[2], s[1], s[3], s[4], s[5]];
                }));
            }),
            App.h('p', { class: 'takeaway' },
              'The cross-season ID is assigned automatically — high confidence rests on name + team or height evidence, ' +
              'medium on looser corroboration; a single-season record has no cross-season match yet. ',
              App.h('a', { href: '#/about' }, 'More about wbb_id'), '.')));
      }, function () {
        // The card shard itself failed to load — a well-formed id whose prefix
        // has no players in this dataset (typo, or a stale link). Same message
        // as a missing id inside a real shard.
        notFound(sec, 'No player with id ' + id + ' — check the id, or search by name at the top of the page.');
      });
    }
  });

  /* ---------- Team page ---------- */

  function retainedPct(r) {
    if (r.retained_next === null || r.retained_next === undefined) return null;
    var denom = (r.retained_next || 0) + (r.transfers_out || 0);
    return denom > 0 ? r.retained_next / denom : null;
  }

  App.register('team', {
    title: function () { return App.titled('Team'); },
    render: function (sec, params) {
      sec.textContent = '';
      var id = params[0] || '';
      if (!/^\d+$/.test(id)) return Promise.resolve(notFound(sec, 'That link has no team id.'));
      var note = App.loading();
      sec.append(note);
      return Promise.all([
        App.getObjects('data/teams.json'),
        App.getObjects('data/team_seasons.json')
      ]).then(function (res) {
        note.remove();
        var team = res[0].find(function (t) { return t.id === id; });
        if (!team) {
          notFound(sec, 'No team with ncaa_id ' + id + ' — try searching its name from the roster explorer.');
          return;
        }
        document.title = App.titled(team.team);
        var rows = res[1].filter(function (r) { return r.ncaa_id === id; })
          .sort(function (a, b) { return a.season_idx - b.season_idx; });

        var head = App.h('div', { class: 'page-head detail-head' },
          App.h('h1', { text: team.team }),
          team.conference ? App.h('span', { class: 'badge', text: team.conference }) : null,
          team.division ? App.h('span', { class: 'badge muted-badge', text: 'Division ' + team.division }) : null);
        var links = App.h('p', {});
        if (team.url) links.append(App.h('a', { href: team.url, target: '_blank', rel: 'noopener', text: 'Official site ↗' }));
        if (team.url && team.twitter) links.append(' · ');
        if (team.twitter) links.append(App.h('a', { href: 'https://twitter.com/' + team.twitter, target: '_blank', rel: 'noopener', text: '@' + team.twitter }));
        if (team.state) links.append((team.url || team.twitter ? ' · ' : '') + team.state);
        sec.append(head, links);

        if (!rows.length) {
          sec.append(App.h('p', { class: 'empty-note',
            text: 'This team is in the teams file, but no roster rows for it appear in the combined seasons.' }));
          return;
        }

        // Per-season summary strip
        var strip = App.h('div', { class: 'summary-strip' });
        rows.forEach(function (r) {
          var season = App.seasons[r.season_idx];
          var pct = retainedPct(r);
          var dl = App.h('dl', {},
            App.h('dt', { text: 'players' }), App.h('dd', { text: String(r.players) }),
            App.h('dt', { text: 'in-state' }),
            App.h('dd', { text: r.in_state === null ? '—' :
              r.us_players ? r.in_state + ' (' + App.fmtPct(r.in_state / r.us_players, 0) + ' of US)' : String(r.in_state) }),
            App.h('dt', { text: 'arrivals' }), App.h('dd', { text: String(orDash(r.transfers_in)) }),
            App.h('dt', { text: 'departures' }), App.h('dd', { text: String(orDash(r.transfers_out)) }),
            App.h('dt', { text: 'retained' }), App.h('dd', { text: pct === null ? '—' : App.fmtPct(pct, 0) }),
            App.h('dt', { text: 'avg height' }), App.h('dd', { text: r.mean_height === null ? '—' : App.fmtHeight(r.mean_height) }));
          strip.append(App.h('div', { class: 'season-card' },
            App.h('h3', {}, season + ' ',
              App.h('a', { href: '#/roster/' + season + '?ncaa_id=' + team.id, text: 'View roster →' })),
            dl));
        });

        // Roster-size bar chart (single series, values on the caps)
        var labels = rows.map(function (r) { return App.seasons[r.season_idx]; });
        var counts = rows.map(function (r) { return r.players; });
        var chartEl = App.h('div', { class: 'chart', style: 'height:260px', role: 'img',
          'aria-label': 'Bar chart of roster size by season' });
        var inst; // created after attach — ECharts measures the container at init
        var biggest = labels[counts.indexOf(Math.max.apply(null, counts))];
        var smallest = labels[counts.indexOf(Math.min.apply(null, counts))];
        var rangeNote = counts.length > 1
          ? 'Rosters ranged from ' + Math.min.apply(null, counts) + ' players in ' + smallest +
            ' to ' + Math.max.apply(null, counts) + ' in ' + biggest + '.'
          : App.fmtNum(counts[0]) + ' players on the ' + labels[0] + ' roster.';

        sec.append(
          App.h('div', { class: 'card' },
            App.h('h2', { style: 'font-size:15px;font-weight:600;margin:0 0 10px', text: 'By season' }),
            strip,
            App.h('p', { class: 'takeaway' },
              'Arrivals and departures count players whose previous or next season was on a different team’s roster; ' +
              'retained is the share of players who appear on any roster the following season who stayed here. ' +
              'First-season arrivals and last-season departures are not yet knowable.')),
          App.h('div', { class: 'card chart-card' },
            App.h('h2', { text: 'Roster size' }),
            chartEl,
            App.takeaway(rangeNote)),
          App.h('div', { class: 'card-foot' },
            App.csvBtn(team.team.toLowerCase().replace(/[^a-z0-9]+/g, '_') + '_seasons.csv', function () {
              return [['season', 'players', 'us_players', 'in_state', 'arrivals', 'departures',
                        'retained_next', 'retained_pct', 'mean_height_inches']]
                .concat(rows.map(function (r) {
                  var pct = retainedPct(r);
                  return [App.seasons[r.season_idx], r.players, r.us_players, r.in_state,
                          r.transfers_in, r.transfers_out, r.retained_next,
                          pct === null ? null : Math.round(pct * 1000) / 10, r.mean_height];
                }));
            })));

        // the card (and chartEl) is attached now, so the chart measures a
        // real container — ECharts on a detached element measures 0×0
        inst = App.chart(chartEl);
        inst.setOption({
          aria: { show: true },
          tooltip: { trigger: 'item' },
          grid: { left: 44, right: 16, top: 30, bottom: 28 },
          xAxis: { type: 'category', data: labels },
          yAxis: { type: 'value' },
          series: [{
            type: 'bar', data: counts, barWidth: 24,
            itemStyle: { color: App.palette[0], borderRadius: [4, 4, 0, 0] },
            label: { show: true, position: 'top', color: '#78716c' }
          }]
        });
      });
    }
  });
})();