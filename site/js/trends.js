/* trends.js — four views of how the rosters themselves have changed:
   1. Class-year composition (stacked bars, absolute ↔ share, COVID freeze caption)
   2. Height by season (boxplot from shipped quantiles ↔ single-season histogram)
   3. Position mix (stacked bars, absolute ↔ share)
   4. Roster scale (two separate single-axis bars: players; teams)
   Chart instances are created once per view render; controls update via setOption. */
(function () {
  'use strict';
  var App = window.App;

  var renderToken = 0; // aborts a superseded render's data fetch (fast re-navigation)

  var YEAR_ORDER = ['Freshman', 'Sophomore', 'Junior', 'Senior', 'Graduate Student',
    'Fifth Year', 'Sixth Year', 'Unknown'];
  var POS_ORDER = ['GUARD', 'FORWARD', 'CENTER', 'WING', 'Unknown'];

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

  function pct1(v) { return v + '%'; }

  App.register('trends', {
    title: function () { return App.titled('Trends'); },
    render: function (sec) {
      sec.textContent = '';
      sec.append(App.loading());
      var token = ++renderToken;
      App.getJSON('data/trends.json').then(function (tr) {
        if (token !== renderToken) return;
        build(sec, tr);
      });
    }
  });

  function build(sec, tr) {
    var seasons = App.seasons;
    var n = seasons.length;
    var totals = tr.season_totals;

    sec.textContent = '';
    sec.append(
      App.h('div', { class: 'page-head' },
        App.h('h1', { text: 'Trends' }),
        App.h('p', { class: 'lede',
          text: 'How the rosters themselves have changed across ' + n + ' seasons — class years, heights, positions and scale. Every chart downloads as CSV.' })));

    /* ---------- shared stacked-bar builder (class & position) ---------- */

    function stackedOption(order, table, mode) {
      var fmt = mode === 'share' ? pct1 : App.fmtNum;
      return {
        aria: { show: true },
        legend: { top: 0, type: 'scroll' },
        tooltip: {
          trigger: 'axis',
          formatter: function (ps) { return App.tip(ps[0].axisValue, ps, fmt); }
        },
        grid: { left: 56, right: 20, top: 48, bottom: 30 },
        xAxis: { type: 'category', data: seasons },
        yAxis: { type: 'value', name: mode === 'share' ? '% of roster' : 'players' },
        series: order.map(function (key, i) {
          var data = table[key].map(function (v, si) {
            return mode === 'share' ? Math.round(v / totals[si] * 1000) / 10 : v;
          });
          return {
            name: key, type: 'bar', stack: 'total', barWidth: 24,
            itemStyle: { color: App.palette[i], borderColor: '#ffffff', borderWidth: 2 },
            emphasis: { itemStyle: { color: App.palette[i] } },
            data: data
          };
        })
      };
    }

    /* ---------- 1. Class-year composition ---------- */

    var classMode = 'count';
    var classEl = App.h('div', { class: 'chart', style: 'height:400px', role: 'img',
      'aria-label': 'Stacked bar chart of class-year composition by season' });
    var classTakeaway = App.h('p', { class: 'takeaway' });
    var classInst; // created after attach — ECharts measures the container at init

    function classUpdate() {
      classInst.setOption(stackedOption(YEAR_ORDER, tr.class_season, classMode), true);
      var extra = ['Graduate Student', 'Fifth Year', 'Sixth Year'];
      function extraShare(si) {
        var s = 0;
        extra.forEach(function (k) { s += tr.class_season[k][si]; });
        return Math.round(s / totals[si] * 1000) / 10;
      }
      var first = extraShare(0), last = extraShare(n - 1);
      classTakeaway.textContent = 'Graduate and extra-year players grew from ' + first +
        '% of rosters in ' + seasons[0] + ' to ' + last + '% in ' + seasons[n - 1] +
        ' — the NCAA’s COVID-19 eligibility freeze gave 2020-21 players an additional year, ' +
        'and class years have run later ever since. Rosters mix academic and athletic standing, so read class year as the roster presented it.';
    }

    sec.append(group(
      radios('Measure', 'trends-class-measure',
        [{ value: 'count', label: 'Players' }, { value: 'share', label: 'Share of roster' }],
        classMode, function (v) { classMode = v; classUpdate(); }),
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Class-year composition' }),
        chartSub('Players per class year in each season (Freshman through Sixth Year, plus blank/unknown). The freeze is visible: extra-year classes barely existed in 2020-21 and grow from 2021-22 onward.'),
        classEl,
        classTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('class_year_composition.csv', function () {
            return [['season'].concat(YEAR_ORDER).concat(['total'])]
              .concat(seasons.map(function (s, si) {
                return [s].concat(YEAR_ORDER.map(function (k) { return tr.class_season[k][si]; }))
                  .concat([totals[si]]);
              }));
          })))));

    /* ---------- 2. Height by season ---------- */

    var hMode = 'box';
    var hSeason = seasons[n - 1];
    var hEl = App.h('div', { class: 'chart', style: 'height:400px', role: 'img',
      'aria-label': 'Chart of player heights by season' });
    var hTakeaway = App.h('p', { class: 'takeaway' });
    var hInst;
    var hSeasonSel = App.select({
      label: 'Histogram season', value: hSeason,
      options: seasons.map(function (s) { return { value: s, label: s }; }),
      onchange: function (v) { hSeason = v; if (hMode === 'hist') hUpdate(); }
    });

    function hUpdate() {
      if (hMode === 'box') {
        hInst.setOption({
          aria: { show: true },
          tooltip: {
            trigger: 'item',
            formatter: function (p) {
              var q = tr.height_quantiles[seasons[p.dataIndex]];
              if (!q) return '';
              return App.esc(seasons[p.dataIndex]) + '<br/><strong>' + App.fmtHeight(q.p50) +
                '</strong> median · ' + App.fmtNum(q.n) + ' players' +
                '<br/>10th: ' + App.fmtHeight(q.p10) + ' · 25th: ' + App.fmtHeight(q.p25) +
                ' · 75th: ' + App.fmtHeight(q.p75) + ' · 90th: ' + App.fmtHeight(q.p90);
            }
          },
          grid: { left: 48, right: 20, top: 20, bottom: 30 },
          xAxis: { type: 'category', data: seasons },
          yAxis: { type: 'value', min: 58, max: 84,
                   axisLabel: { formatter: App.fmtHeight } },
          series: [{
            type: 'boxplot', boxWidth: 22,
            itemStyle: { color: '#dbeafe', borderColor: App.palette[0] },
            data: seasons.map(function (s) {
              var q = tr.height_quantiles[s];
              return [q.p10, q.p25, q.p50, q.p75, q.p90];
            })
          }]
        }, true);
        var q0 = tr.height_quantiles[seasons[0]], q1 = tr.height_quantiles[seasons[n - 1]];
        var allSame = seasons.every(function (s) { return tr.height_quantiles[s].p50 === q0.p50; });
        hTakeaway.textContent = 'Median height has held at ' + App.fmtHeight(q0.p50) +
          (allSame ? ' every season' : ' in ' + seasons[0] + ' and ' + App.fmtHeight(q1.p50) + ' in ' + seasons[n - 1]) +
          '; half of all players stand between ' + App.fmtHeight(q1.p25) + ' and ' + App.fmtHeight(q1.p75) +
          '. Box = middle half (25th–75th percentile), line = median, whiskers = 10th–90th. ' +
          'Heights outside 58–90 inches are treated as scrape/parse errors and excluded.';
      } else {
        var bins = tr.height_bins[hSeason];
        hInst.setOption({
          aria: { show: true },
          tooltip: {
            trigger: 'item',
            formatter: function (p) {
              return App.esc(hSeason) + ' · ' + App.esc(p.name) + ' inches<br/><strong>' +
                App.fmtNum(p.value) + '</strong> players';
            }
          },
          grid: { left: 56, right: 20, top: 20, bottom: 34 },
          xAxis: { type: 'category', data: bins.map(function (b) { return b[0]; }),
                   name: 'height (inches)', nameLocation: 'middle', nameGap: 24 },
          yAxis: { type: 'value', name: 'players' },
          series: [{
            type: 'bar', barWidth: 24,
            itemStyle: { color: App.palette[0], borderRadius: [4, 4, 0, 0] },
            data: bins.map(function (b) { return b[1]; })
          }]
        }, true);
        var peak = bins.reduce(function (a, b) { return b[1] > a[1] ? b : a; }, bins[0]);
        var q = tr.height_quantiles[hSeason];
        hTakeaway.textContent = 'In ' + hSeason + ', ' + App.fmtNum(q.n) + ' players have a parsed height; the most common band is ' +
          peak[0] + ' inches (' + App.fmtNum(peak[1]) + ' players) and the median is ' + App.fmtHeight(q.p50) + '.';
      }
    }

    var hModeRadios = radios('View', 'trends-height-mode',
      [{ value: 'box', label: 'Boxplot by season' }, { value: 'hist', label: 'Histogram' }],
      hMode, function (v) {
        hMode = v;
        hSeasonSel.hidden = (v === 'box');
        hUpdate();
      });

    sec.append(group(
      [hModeRadios, hSeasonSel],
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Heights' }),
        chartSub('The height distribution each season, from the parsed total-inches field (98% coverage; values outside 58–90 inches are excluded as errors).'),
        hEl,
        hTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('height_quantiles.csv', function () {
            return [['season', 'n', 'min', 'p10', 'p25', 'median', 'p75', 'p90', 'max']]
              .concat(seasons.map(function (s) {
                var q = tr.height_quantiles[s];
                return [s, q.n, q.min, q.p10, q.p25, q.p50, q.p75, q.p90, q.max];
              }));
          })))));

    /* ---------- 3. Position mix ---------- */

    var posMode = 'count';
    var posEl = App.h('div', { class: 'chart', style: 'height:360px', role: 'img',
      'aria-label': 'Stacked bar chart of position mix by season' });
    var posTakeaway = App.h('p', { class: 'takeaway' });
    var posInst;

    function posUpdate() {
      posInst.setOption(stackedOption(POS_ORDER, tr.position_season, posMode), true);
      function share(key, si) {
        return Math.round(tr.position_season[key][si] / totals[si] * 1000) / 10;
      }
      posTakeaway.textContent = 'Guards are the biggest group every season — ' +
        share('GUARD', n - 1) + '% of rostered players in ' + seasons[n - 1] +
        ' (from ' + share('GUARD', 0) + '% in ' + seasons[0] + '). Positions come from the roster position field; ' +
        'players with none listed count as Unknown.';
    }

    sec.append(group(
      radios('Measure', 'trends-pos-measure',
        [{ value: 'count', label: 'Players' }, { value: 'share', label: 'Share of roster' }],
        posMode, function (v) { posMode = v; posUpdate(); }),
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Position mix' }),
        chartSub('Primary position (guard, forward, center, wing) per season, derived from the roster position field.'),
        posEl,
        posTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('position_mix.csv', function () {
            return [['season'].concat(POS_ORDER).concat(['total'])]
              .concat(seasons.map(function (s, si) {
                return [s].concat(POS_ORDER.map(function (k) { return tr.position_season[k][si]; }))
                  .concat([totals[si]]);
              }));
          })))));

    /* ---------- 4. Roster scale ---------- */

    var plEl = App.h('div', { class: 'chart', style: 'height:300px', role: 'img',
      'aria-label': 'Bar chart of players per season' });
    var tmEl = App.h('div', { class: 'chart', style: 'height:300px', role: 'img',
      'aria-label': 'Bar chart of teams per season' });
    var scaleTakeaway = App.h('p', { class: 'takeaway' });
    var plInst, tmInst;

    var players = tr.scale.map(function (r) { return r[2]; });
    var teamCount = tr.scale.map(function (r) { return r[1]; });

    function scaleOption(values, name) {
      return {
        aria: { show: true },
        tooltip: {
          trigger: 'item',
          formatter: function (p) {
            return App.esc(seasons[p.dataIndex]) + '<br/><strong>' + App.fmtNum(p.value) + '</strong> ' + name;
          }
        },
        grid: { left: 56, right: 20, top: 24, bottom: 30 },
        xAxis: { type: 'category', data: seasons },
        yAxis: { type: 'value', name: name },
        series: [{
          type: 'bar', barWidth: 24,
          itemStyle: { color: App.palette[0], borderRadius: [4, 4, 0, 0] },
          label: { show: true, position: 'top', color: '#78716c',
                   formatter: function (p) { return App.fmtNum(p.value); } },
          data: values
        }]
      };
    }
    scaleTakeaway.textContent = 'From ' + seasons[0] + ' to ' + seasons[n - 1] + ' the data grew from ' +
      App.fmtNum(players[0]) + ' players on ' + App.fmtNum(teamCount[0]) + ' teams to ' +
      App.fmtNum(players[n - 1]) + ' players on ' + App.fmtNum(teamCount[n - 1]) + ' teams; the average roster ' +
      'rose from ' + tr.scale[0][3] + ' to ' + tr.scale[n - 1][3] + ' players.';

    sec.append(App.h('section', { class: 'card chart-card' },
      App.h('h2', { text: 'Roster scale' }),
      chartSub('How many players and teams the rosters cover each season.'),
      App.h('div', { class: 'two-col' },
        App.h('div', {},
          App.h('h3', { style: 'font-size:13px;font-weight:600;margin:0 0 4px', text: 'Players per season' }), plEl),
        App.h('div', {},
          App.h('h3', { style: 'font-size:13px;font-weight:600;margin:0 0 4px', text: 'Teams per season' }), tmEl)),
      scaleTakeaway,
      App.h('div', { class: 'card-foot' },
        App.csvBtn('roster_scale.csv', function () {
          return [['season', 'teams', 'players', 'avg_roster_size', 'median_height_inches']]
            .concat(tr.scale.map(function (r) {
              return [seasons[r[0]], r[1], r[2], r[3], r[4]];
            }));
        }))));

    /* ---------- initial renders ---------- */

    // All cards are attached by this point, so the chart instances finally
    // measure a real container — ECharts on a detached element measures 0×0.
    classInst = App.chart(classEl);
    hInst = App.chart(hEl);
    posInst = App.chart(posEl);
    plInst = App.chart(plEl);
    tmInst = App.chart(tmEl);
    plInst.setOption(scaleOption(players, 'players'), true);
    tmInst.setOption(scaleOption(teamCount, 'teams'), true);

    classUpdate();
    hUpdate();
    posUpdate();
    hSeasonSel.hidden = true; // histogram season only applies in histogram view
  }
})();