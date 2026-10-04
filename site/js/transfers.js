/* transfers.js — five views of how players move, built on the cross-season
   wbb_id (season-over-season moves between teams):
   1. Conference-flow Sankey (pair selector, top 12 conferences by degree)
   2. Team-flow Sankey (pair + min-players selectors; click a team → team page)
   3. Most-traveled players (everyone with 3+ distinct teams, with every stop)
   4. Feeder programs (top 25; blue = four-year program, gray = JuCO/prep)
   5. Roster turnover (pair selector, top/bottom 15 retained %, + full table)
   A Sankey requires a DAG, but transfer graphs contain cycles (players move
   both ways), so both Sankeys keep edges largest-first and skip any edge that
   would close a cycle — dropped edges are reported and stay in the CSV.
   Move counts are a floor: borderline identity matches await human review. */
(function () {
  'use strict';
  var App = window.App;

  var trTables = []; // Tabulator instances to destroy on route change
  var renderToken = 0; // aborts a superseded render's data fetch (fast re-navigation)

  var ACCENT = '#1d4ed8';
  var LINK = 'rgba(29,78,216,0.18)';

  function group(controls, card) {
    var g = App.h('div', { class: 'chart-group' });
    if (controls) g.append(App.h('div', { class: 'controls' }, controls));
    g.append(card);
    return g;
  }

  function chartSub(text) {
    return App.h('p', { class: 'chart-sub', text: text });
  }

  function swatchLegend(items) {
    var row = App.h('div', { class: 'radio-row', style: 'margin:0 0 10px' });
    items.forEach(function (it) {
      row.append(App.h('span', { class: 'legend-item', role: 'listitem' },
        App.h('span', { class: 'legend-swatch', style: 'background:' + it.color }),
        it.label));
    });
    return row;
  }

  // Greedy DAG extraction: edges must arrive sorted by value desc. An edge is
  // kept unless its target can already reach its source (a cycle), or it is a
  // self-loop — a Sankey node cannot flow into itself.
  function dagEdges(edges) {
    var adj = {}, kept = [], dropped = 0;
    function reaches(from, to) {
      if (from === to) return true;
      var seen = {}, stack = [from];
      while (stack.length) {
        var u = stack.pop();
        var next = adj[u] || [];
        for (var i = 0; i < next.length; i++) {
          if (next[i] === to) return true;
          if (!seen[next[i]]) { seen[next[i]] = 1; stack.push(next[i]); }
        }
      }
      return false;
    }
    edges.forEach(function (e) {
      if (e.source === e.target || reaches(e.target, e.source)) { dropped++; return; }
      (adj[e.source] = adj[e.source] || []).push(e.target);
      kept.push(e);
    });
    return { kept: kept, dropped: dropped };
  }

  // Shared Sankey rendering: nodes single-hue blue, links translucent blue.
  function sankeyOption(nodes, links, nodeFlow, nodeGap) {
    return {
      aria: { show: true },
      tooltip: {
        trigger: 'item',
        formatter: function (p) {
          if (p.dataType === 'edge') {
            return App.esc(p.data.source) + ' → ' + App.esc(p.data.target) +
              '<br/><strong>' + App.fmtNum(p.data.value) + '</strong> player' +
              (p.data.value === 1 ? '' : 's') + ' moved';
          }
          var f = nodeFlow[p.name] || { out: 0, in: 0 };
          return App.esc(p.name) + '<br/>moved out: <strong>' + App.fmtNum(f.out) +
            '</strong> · arrived: <strong>' + App.fmtNum(f.in) + '</strong>';
        }
      },
      series: [{
        type: 'sankey', data: nodes, links: links,
        left: 8, right: 150, top: 8, bottom: 8,
        nodeWidth: 12, nodeGap: nodeGap || 10,
        emphasis: { focus: 'adjacency' },
        lineStyle: { color: LINK, curveness: 0.5 },
        label: { color: '#1c1917', fontSize: 11 },
        itemStyle: { color: ACCENT }
      }]
    };
  }

  function flowOf(kept) {
    var flow = {};
    kept.forEach(function (e) {
      (flow[e.source] = flow[e.source] || { out: 0, in: 0 }).out += e.value;
      (flow[e.target] = flow[e.target] || { out: 0, in: 0 }).in += e.value;
    });
    return flow;
  }

  App.register('transfers', {
    title: function () { return App.titled('Transfers'); },
    cleanup: function () {
      trTables.forEach(function (t) { try { t.destroy(); } catch (e) { /* gone */ } });
      trTables = [];
    },
    render: function (sec) {
      sec.textContent = '';
      sec.append(App.loading());
      var token = ++renderToken;
      return Promise.all([
        App.getJSON('data/transfers.json'),
        App.getObjects('data/teams.json'),
        App.getObjects('data/team_seasons.json')
      ]).then(function (res) {
        if (token !== renderToken) return;
        build(sec, res[0], res[1], res[2]);
      });
    }
  });

  function build(sec, tr, teamsList, teamSeasons) {
    var seasons = App.seasons;
    var lastSeason = seasons[seasons.length - 1];
    var pairs = tr.pairs;
    var totalMoves = tr.moves_per_pair.reduce(function (a, b) { return a + b; }, 0);

    // Current team names, disambiguated if two ids share a name (Sankey keys
    // nodes by name). Historic names live in most_traveled stops as scraped.
    var rawName = {}, nameCount = {};
    teamsList.forEach(function (t) { rawName[t.id] = t.team; nameCount[t.team] = (nameCount[t.team] || 0) + 1; });
    var teamById = {};
    teamsList.forEach(function (t) {
      teamById[t.id] = nameCount[t.team] > 1 && t.state ? t.team + ' (' + t.state + ')' : t.team;
    });
    function nameOf(id) { return teamById[id] || ('#' + id); }

    function pairOptions() {
      return pairs.map(function (p, i) {
        return { value: String(i), label: p + ' · ' + App.fmtNum(tr.moves_per_pair[i]) + ' moves' };
      });
    }

    sec.textContent = '';
    sec.append(
      App.h('div', { class: 'page-head' },
        App.h('h1', { text: 'Transfers' }),
        App.h('p', { class: 'lede',
          text: 'Where players move, season over season, matched by the stable cross-season ID: ' +
            App.fmtNum(totalMoves) + ' matched moves across ' + pairs.length + ' season windows. ' +
            'A floor, not a ceiling — borderline identity matches await human review, so counts can only rise.' })));

    /* ---------- 1. Conference-flow Sankey ---------- */

    var confState = { pair: 0 };
    var confEl = App.h('div', { class: 'chart', style: 'height:560px', role: 'img',
      'aria-label': 'Sankey diagram of conference-to-conference player moves' });
    var confTakeaway = App.h('p', { class: 'takeaway' });
    var confInst; // created after attach — ECharts measures the container at init

    function confUpdate() {
      var all = tr.conf_edges.filter(function (e) { return e[0] === confState.pair; })
        .map(function (e) { return { source: e[1], target: e[2], value: e[3] }; });
      // Top 12 conferences by degree: distinct partner conferences
      var partners = {};
      function bump(name, other) {
        if (!partners[name]) partners[name] = { partners: {} };
        partners[name].partners[other] = 1;
      }
      all.forEach(function (e) {
        if (e.source === e.target) return; // within-conference moves aren't drawable
        bump(e.source, e.target);
        bump(e.target, e.source);
      });
      var top = Object.keys(partners)
        .sort(function (a, b) {
          return Object.keys(partners[b].partners).length - Object.keys(partners[a].partners).length ||
            (a < b ? -1 : 1);
        }).slice(0, 12);
      var inTop = {};
      top.forEach(function (c) { inTop[c] = true; });
      var shown = all.filter(function (e) { return inTop[e.source] && inTop[e.target]; })
        .sort(function (a, b) { return b.value - a.value || (a.source < b.source ? -1 : 1); })
        .slice(0, 30); // the top-12 mesh is dense; cap at the 30 largest flows
      var dag = dagEdges(shown);
      var flow = flowOf(dag.kept);
      var nodes = Object.keys(flow).sort(function (a, b) {
        return (flow[b].out + flow[b].in) - (flow[a].out + flow[a].in);
      }).map(function (n) { return { name: n }; });

      confInst.setOption(sankeyOption(nodes, dag.kept, flow), true);

      var biggest = dag.kept[0];
      confTakeaway.textContent =
        (biggest ? 'Biggest flow: ' + biggest.source + ' → ' + biggest.target + ' (' + App.fmtNum(biggest.value) + ' players). ' : '') +
        'The 30 largest flows among the 12 most-connected conferences are shown' +
        (dag.dropped ? '; ' + dag.dropped + ' two-way flows kept only their larger direction (a flow diagram can’t loop)' : '') +
        '. Moves within a single conference aren’t drawable. Click a conference to open its rosters; the CSV has every conference-to-conference move.';
    }

    sec.append(group(
      App.select({
        label: 'Season window', value: String(confState.pair),
        options: pairOptions(),
        onchange: function (v) { confState.pair = +v; confUpdate(); }
      }),
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Conference-to-conference moves' }),
        chartSub('Player moves between conferences for the chosen window; the width of each flow is the number of players.'),
        confEl,
        confTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('conference_moves_' + seasons[confState.pair].replace(/-/g, '_') + '.csv', function () {
            return [['season_window', 'from_conference', 'to_conference', 'players']]
              .concat(tr.conf_edges.filter(function (e) { return e[0] === confState.pair; })
                .map(function (e) { return [pairs[e[0]], e[1], e[2], e[3]]; }));
          })))));

    /* ---------- 2. Team-flow Sankey ---------- */

    var teamState = { pair: 1, min: 2 }; // default ≥2 players per move
    var teamEl = App.h('div', { class: 'chart', style: 'height:760px', role: 'img',
      'aria-label': 'Sankey diagram of team-to-team player moves' });
    var teamTakeaway = App.h('p', { class: 'takeaway' });
    var teamInst;

    function teamUpdate() {
      var edges = tr.team_edges.filter(function (e) { return e[0] === teamState.pair; })
        .map(function (e) {
          return { source: nameOf(e[1]), target: nameOf(e[2]), value: e[3], fromId: e[1], toId: e[2] };
        })
        .sort(function (a, b) { return b.value - a.value || (a.source < b.source ? -1 : 1); });
      var shown = teamState.min === 0
        ? edges.slice(0, 60) // "all moves": the 60 largest, capped for readability
        : edges.filter(function (e) { return e.value >= 2; }).slice(0, 25); // multi-player routes, 25 largest
      var dag = dagEdges(shown);
      var flow = flowOf(dag.kept);
      var nodes = Object.keys(flow).sort(function (a, b) {
        return (flow[b].out + flow[b].in) - (flow[a].out + flow[a].in);
      }).map(function (n) {
        return { name: n, nid: null };
      });
      // Attach ids back through the disambiguated names
      var idByName = {};
      edges.forEach(function (e) { if (!idByName[e.source]) idByName[e.source] = e.fromId; });
      nodes.forEach(function (n) { n.nid = idByName[n.name]; });

      teamInst.setOption(sankeyOption(nodes, dag.kept, flow, 8), true);

      teamTakeaway.textContent =
        (teamState.min === 0
          ? 'The 60 largest single moves of the window are shown. '
          : 'The 25 largest multi-player moves are shown — routes taken by two or more players. ') +
        (dag.dropped ? dag.dropped + ' two-way flows kept only their larger direction. ' : '') +
        'Click a team to open its page; the CSV has every move for this window.';
    }

    sec.append(group(
      [
        App.select({
          label: 'Season window', value: String(teamState.pair),
          options: pairOptions(),
          onchange: function (v) { teamState.pair = +v; teamUpdate(); }
        }),
        App.select({
          label: 'Moves to show', value: '2',
          options: [
            { value: '2', label: 'Multi-player moves (top 25)' },
            { value: '0', label: 'All moves (top 60)' }
          ],
          onchange: function (v) { teamState.min = +v; teamUpdate(); }
        })
      ],
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Team-to-team moves' }),
        chartSub('The direct routes players take between programs — the biggest single-team pipelines for the chosen window.'),
        teamEl,
        teamTakeaway,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('team_moves_' + seasons[teamState.pair].replace(/-/g, '_') + '.csv', function () {
            return [['season_window', 'from_team', 'from_ncaa_id', 'to_team', 'to_ncaa_id', 'players']]
              .concat(tr.team_edges.filter(function (e) { return e[0] === teamState.pair; })
                .map(function (e) {
                  return [pairs[e[0]], rawName[e[1]] || e[1], e[1], rawName[e[2]] || e[2], e[2], e[3]];
                }));
          })))));

    /* ---------- 3. Most-traveled players ---------- */

    function stopsText(stops, arrow) {
      return stops.map(function (s) {
        return s[2] + ' (' + seasons[s[0]] + ')';
      }).join(arrow || ' → ');
    }

    var mtEl = App.h('div');
    sec.append(App.h('section', { class: 'card' },
      App.h('h2', { text: 'The most-traveled players' }),
      chartSub('Every player who appeared on at least three distinct teams, with every roster stop. Click a name to open her player page.'),
      mtEl,
      App.h('div', { class: 'card-foot' },
        App.csvBtn('most_traveled_players.csv', function () {
          return [['wbb_id', 'name', 'teams', 'stops']]
            .concat(tr.most_traveled.map(function (m) {
              return [m.id, m.name, m.n_teams, stopsText(m.stops, ' -> ')];
            }));
        }))));

    var mtTable = new Tabulator(mtEl, {
      data: tr.most_traveled.map(function (m) {
        return { id: m.id, name: m.name, n_teams: m.n_teams, stops: stopsText(m.stops) };
      }),
      index: 'id',
      columns: [
        { title: 'Player', field: 'name', minWidth: 160, maxWidth: 240,
          headerFilter: 'input', headerFilterPlaceholder: 'filter',
          formatter: function (cell) {
            var d = cell.getData();
            return App.h('a', { href: '#/player/' + d.id, text: d.name });
          } },
        { title: 'Teams', field: 'n_teams', minWidth: 70, sorter: 'number', hozAlign: 'right', width: 80 },
        { title: 'Roster stops', field: 'stops', minWidth: 320, maxWidth: 560,
          formatter: 'textarea', cssClass: 'stops-cell',
          variableHeight: true }
      ],
      layout: 'fitDataStretch',
      height: 480,
      selectableRows: false,
      placeholder: 'No players match.',
      initialSort: [{ column: 'n_teams', dir: 'desc' }, { column: 'name', dir: 'asc' }]
    });
    trTables.push(mtTable);

    /* ---------- 4. Feeder programs ---------- */

    var feeders = tr.feeders; // [previous_school, players, mentions, is_team], players desc
    var fdEl = App.h('div', { class: 'chart', style: 'height:640px', role: 'img',
      'aria-label': 'Bar chart of the most common previous schools' });
    var fdTakeaway = App.h('p', { class: 'takeaway' });
    var fdInst;
    var top25 = feeders.slice(0, 25);
    var knownCount = top25.filter(function (f) { return f[3]; }).length;

    fdTakeaway.textContent = top25[0][0] + ' leads: ' + App.fmtNum(top25[0][1]) +
      ' distinct players listed it as a previous school. ' + knownCount + ' of the top 25 are four-year programs — ' +
      'college-to-college moves dominate, with ' + (25 - knownCount) + ' JuCO, prep or other routes.';

    sec.append(App.h('section', { class: 'card chart-card' },
      App.h('h2', { text: 'Feeder programs' }),
      chartSub('The previous schools named most often on these rosters (minimum 5 distinct players), top 25. From the roster’s previous-school field — sparse and inconsistently formatted, so this undercounts.'),
      swatchLegend([
        { color: ACCENT, label: 'Four-year program' },
        { color: App.feederGray, label: 'JuCO, prep or other' }
      ]),
      fdEl,
      fdTakeaway,
      App.h('div', { class: 'card-foot' },
        App.csvBtn('feeder_programs.csv', function () {
          return [['previous_school', 'distinct_players', 'roster_mentions', 'is_four_year_program']]
            .concat(feeders.map(function (f) { return [f[0], f[1], f[2], f[3] ? 'TRUE' : 'FALSE']; }));
        }))));

    /* ---------- 5. Roster turnover ---------- */

    var toState = { pair: 0 };
    var toTopEl = App.h('div', { class: 'chart', style: 'height:440px', role: 'img',
      'aria-label': 'Bar chart of teams with the highest share of players retained' });
    var toBotEl = App.h('div', { class: 'chart', style: 'height:440px', role: 'img',
      'aria-label': 'Bar chart of teams with the lowest share of players retained' });
    var toTakeaway = App.h('p', { class: 'takeaway' });
    var toTableEl = App.h('div', { style: 'margin-top:14px' });
    var toTopInst, toBotInst;
    var toTable = null;
    var toRows = [];

    function turnoverOption(rows) {
      return {
        aria: { show: true },
        tooltip: {
          trigger: 'item',
          formatter: function (p) {
            var d = p.data && p.data.raw;
            if (!d) return '';
            return App.esc(d.team) + '<br/><strong>' + App.fmtPct(d.pct) + '</strong> retained (' +
              d.retained + ' stayed · ' + d.out + ' left)';
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
          itemStyle: { color: ACCENT, borderRadius: [0, 4, 4, 0] },
          label: { show: true, position: 'right', color: '#78716c',
                   formatter: function (p) { return App.fmtPct(p.data.raw.pct, 0); } },
          data: rows.map(function (d) { return { value: d.pct, raw: d }; })
        }]
      };
    }

    function toUpdate() {
      toRows = [];
      teamSeasons.forEach(function (r) {
        if (r.season_idx !== toState.pair) return;
        if (!r.players || r.players < 10) return;
        if (r.retained_next === null || r.transfers_out === null) return;
        var denom = r.retained_next + r.transfers_out;
        if (!denom) return;
        var t = teamById[r.ncaa_id];
        if (!t) return;
        toRows.push({ team: t, id: r.ncaa_id, pct: r.retained_next / denom,
                      retained: r.retained_next, out: r.transfers_out, players: r.players });
      });
      toRows.sort(function (a, b) { return b.pct - a.pct || (a.team < b.team ? -1 : 1); });
      toTopInst.setOption(turnoverOption(toRows.slice(0, 15)), true);
      toBotInst.setOption(turnoverOption(toRows.slice(-15).reverse()), true);

      var mean = toRows.reduce(function (a, d) { return a + d.pct; }, 0) / (toRows.length || 1);
      toTakeaway.textContent = 'In ' + pairs[toState.pair] + ', teams with at least 10 players kept on average ' +
        App.fmtPct(mean) + ' of the players who appeared on any roster the next season. ' +
        'Click a bar to open the team.';

      if (toTable) { try { toTable.destroy(); } catch (e) { /* gone */ } }
      toTable = new Tabulator(toTableEl, {
        data: toRows.map(function (d) {
          return { key: d.id, team: d.team, id: d.id, players: d.players,
                   retained: d.retained, out: d.out, pct: Math.round(d.pct * 1000) / 10 };
        }),
        index: 'key',
        columns: [
          { title: 'Team', field: 'team', minWidth: 170, maxWidth: 280,
            headerFilter: 'input', headerFilterPlaceholder: 'filter',
            formatter: function (cell) {
              var d = cell.getData();
              return App.h('a', { href: '#/team/' + d.id, text: d.team });
            } },
          { title: 'Players', field: 'players', minWidth: 90, sorter: 'number', hozAlign: 'right' },
          { title: 'Retained', field: 'retained', minWidth: 90, sorter: 'number', hozAlign: 'right' },
          { title: 'Left', field: 'out', minWidth: 70, sorter: 'number', hozAlign: 'right' },
          { title: 'Retained %', field: 'pct', minWidth: 100, sorter: 'number', hozAlign: 'right' }
        ],
        layout: 'fitDataStretch',
        height: 380,
        selectableRows: false,
        placeholder: 'No teams match.',
        initialSort: [{ column: 'pct', dir: 'desc' }]
      });
      trTables.push(toTable); // cleanup destroys it (stale handles no-op)
    }

    sec.append(group(
      App.select({
        label: 'Season window', value: String(toState.pair),
        options: pairOptions(),
        onchange: function (v) { toState.pair = +v; toUpdate(); }
      }),
      App.h('section', { class: 'card chart-card' },
        App.h('h2', { text: 'Roster turnover' }),
        chartSub('Share of each team’s roster that stayed for the next season — retained % counts only players who appear on any roster the following season (stayers + matched movers). Teams with at least 10 players; the 15 highest and 15 lowest.'),
        App.h('div', { class: 'two-col' },
          App.h('div', {},
            App.h('h3', { style: 'font-size:13px;font-weight:600;margin:0 0 4px', text: 'Most retained' }), toTopEl),
          App.h('div', {},
            App.h('h3', { style: 'font-size:13px;font-weight:600;margin:0 0 4px', text: 'Least retained' }), toBotEl)),
        toTakeaway,
        App.h('h3', { style: 'font-size:13px;font-weight:600;margin:16px 0 0', text: 'All teams for this window' }),
        toTableEl,
        App.h('div', { class: 'card-foot' },
          App.csvBtn('roster_turnover_' + seasons[toState.pair].replace(/-/g, '_') + '.csv', function () {
            return [['season_window', 'team', 'ncaa_id', 'players', 'retained_next', 'transfers_out', 'retained_pct']]
              .concat(toRows.map(function (d) {
                return [pairs[toState.pair], d.team, d.id, d.players, d.retained, d.out,
                        Math.round(d.pct * 1000) / 10];
              }));
          })))));

    /* ---------- initial renders ---------- */

    // All cards are attached by this point, so the chart instances finally
    // measure a real container — ECharts on a detached element measures 0×0.
    confInst = App.chart(confEl);
    confInst.on('click', function (p) {
      if (p.dataType === 'node' && p.name) {
        location.hash = '#/roster/' + lastSeason + '?conference=' + encodeURIComponent(p.name);
      }
    });
    teamInst = App.chart(teamEl);
    teamInst.on('click', function (p) {
      if (p.dataType === 'node' && p.data && p.data.nid) {
        location.hash = '#/team/' + p.data.nid;
      }
    });
    fdInst = App.chart(fdEl);
    fdInst.setOption({
      aria: { show: true },
      tooltip: {
        trigger: 'item',
        formatter: function (p) {
          var f = p.data && p.data.raw;
          if (!f) return '';
          return App.esc(f[0]) + '<br/><strong>' + App.fmtNum(f[1]) + '</strong> distinct players · ' +
            App.fmtNum(f[2]) + ' roster mentions · ' + (f[3] ? 'four-year program' : 'JuCO / prep / other');
        }
      },
      grid: { left: 150, right: 56, top: 10, bottom: 28 },
      xAxis: { type: 'value', name: 'distinct players' },
      yAxis: {
        type: 'category', inverse: true,
        data: top25.map(function (f) { return f[0]; }),
        axisLabel: { width: 140, overflow: 'truncate' }
      },
      series: [{
        type: 'bar', barWidth: 16,
        itemStyle: { borderRadius: [0, 4, 4, 0] },
        label: { show: true, position: 'right', color: '#78716c' },
        data: top25.map(function (f) {
          return { value: f[1], raw: f, itemStyle: { color: f[3] ? ACCENT : App.feederGray } };
        })
      }]
    }, true);
    toTopInst = App.chart(toTopEl);
    toBotInst = App.chart(toBotEl);
    toTopInst.on('click', function (p) { if (p.data && p.data.raw) location.hash = '#/team/' + p.data.raw.id; });
    toBotInst.on('click', function (p) { if (p.data && p.data.raw) location.hash = '#/team/' + p.data.raw.id; });

    confUpdate();
    teamUpdate();
    toUpdate();
  }
})();