/* core.js — app shell: design tokens, utilities, hash router, data cache,
   global player search, home and about views. Chart bundles and the roster
   explorer register themselves with App.register() at load time.

   All paths are relative so the site works on the GitHub Pages subpath. */
(function () {
  'use strict';

  var App = (window.App = {});

  /* ---------- Design tokens (validated palette; see docs/plans/2026-10-03-website-design.md) ---------- */

  App.palette = ['#1d4ed8', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#4a3aa7', '#e34948'];
  App.seqRamp = ['#dbeafe', '#bfdbfe', '#93c5fd', '#60a5fa', '#2563eb', '#1d4ed8'];
  App.noData = '#e7e5e4';
  App.feederGray = '#a8a29e';

  if (window.echarts) {
    echarts.registerTheme('wbb', {
      color: App.palette,
      backgroundColor: 'transparent',
      textStyle: {
        fontFamily: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
        color: '#1c1917',
        fontSize: 12
      },
      legend: { itemWidth: 12, itemHeight: 8, icon: 'roundRect', textStyle: { color: '#78716c' } },
      tooltip: {
        backgroundColor: '#ffffff',
        borderColor: '#e7e5e4',
        borderWidth: 1,
        textStyle: { color: '#1c1917', fontSize: 12 },
        extraCssText: 'box-shadow: 0 2px 10px rgba(28,25,23,0.12); border-radius: 6px; padding: 8px 10px;'
      },
      categoryAxis: {
        axisLine: { lineStyle: { color: '#d6d3d1' } },
        axisTick: { show: false },
        axisLabel: { color: '#78716c' },
        splitLine: { show: false }
      },
      valueAxis: {
        axisLine: { show: false },
        axisTick: { show: false },
        axisLabel: { color: '#78716c' },
        splitLine: { lineStyle: { color: '#e7e5e4', width: 1, type: 'solid' } }
      }
    });
  }

  /* ---------- Utilities ---------- */

  // DOM builder; children may be nodes, strings, numbers or arrays. Untrusted
  // text (player names, hometowns) always goes through text nodes.
  App.h = function (tag, attrs) {
    var el = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === null || v === undefined) return;
        if (k === 'text') el.textContent = v;
        else if (k === 'class') el.className = v;
        else if (k.slice(0, 2) === 'on') el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, v);
      });
    }
    for (var i = 2; i < arguments.length; i++) {
      flatten(el, arguments[i]);
    }
    return el;
  };
  function flatten(el, c) {
    if (c === null || c === undefined) return;
    if (Array.isArray(c)) { c.forEach(function (x) { flatten(el, x); }); return; }
    el.append(c.nodeType ? c : document.createTextNode(String(c)));
  }

  App.esc = function (s) {
    return String(s === null || s === undefined ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  };

  App.fmtNum = function (n) {
    return n === null || n === undefined ? '' : Number(n).toLocaleString('en-US');
  };

  App.fmtPct = function (x, digits) {
    return (100 * x).toFixed(digits === undefined ? 1 : digits) + '%';
  };

  App.fmtHeight = function (inches) {
    if (inches === null || inches === undefined || inches === '') return '';
    return Math.floor(inches / 12) + "'" + (inches % 12) + '"';
  };

  // CSV download, repo convention: every field quoted.
  App.downloadCsv = function (filename, rows) {
    var q = function (v) {
      if (v === null || v === undefined) return '""';
      return '"' + String(v).replace(/"/g, '""') + '"';
    };
    var lines = rows.map(function (r) { return r.map(q).join(','); });
    var blob = new Blob([lines.join('\n') + '\n'], { type: 'text/csv;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  };

  App.csvBtn = function (filename, getRows) {
    return App.h('button', { class: 'btn btn-sm', type: 'button', onclick: function () { App.downloadCsv(filename, getRows()); } }, 'Download CSV');
  };

  App.takeaway = function (text) {
    return App.h('p', { class: 'takeaway', text: text });
  };

  // A labeled select, used by the chart bundles' control rows.
  App.select = function (opts) {
    var sel = App.h('select', {
      'aria-label': opts.ariaLabel || opts.label,
      onchange: function (e) { opts.onchange(e.target.value); }
    });
    (opts.options || []).forEach(function (o) {
      var opt = App.h('option', { value: o.value }, o.label);
      if (o.value === opts.value) opt.selected = true;
      sel.append(opt);
    });
    return App.h('label', { class: 'control' },
      App.h('span', { class: 'control-label', text: opts.label }), sel);
  };

  App.errorBox = function (err) {
    return App.h('div', { class: 'error-box', role: 'alert' },
      App.h('strong', { text: 'Something went wrong loading this page. ' }),
      String((err && err.message) ? err.message : err));
  };

  App.loading = function (text) {
    return App.h('p', { class: 'empty-note', text: text || 'Loading…' });
  };

  // Tooltip rows: the value is the strong element, the series name secondary,
  // each row keyed by a short stroke of the series color (never a filled box).
  App.tip = function (title, params, fmt) {
    fmt = fmt || App.fmtNum;
    var rows = params.slice().sort(function (a, b) { return (b.value || 0) - (a.value || 0); });
    var html = '<div style="font-weight:600;margin-bottom:2px">' + App.esc(title) + '</div>';
    rows.forEach(function (p) {
      var color = typeof p.color === 'string' ? p.color :
        (p.color && p.color.colorStops) ? p.color.colorStops[p.color.colorStops.length - 1].color : '#78716c';
      html += '<div style="line-height:1.7">' +
        '<span style="display:inline-block;width:10px;height:2px;vertical-align:middle;margin-right:5px;background:' + color + '"></span>' +
        '<strong>' + fmt(p.value) + '</strong> ' + App.esc(p.seriesName) + '</div>';
    });
    return html;
  };

  /* ---------- Data cache ---------- */

  var jsonCache = new Map();
  App.getJSON = function (path) {
    if (!jsonCache.has(path)) {
      jsonCache.set(path, fetch(path).then(function (r) {
        if (!r.ok) throw new Error(path + ' — HTTP ' + r.status);
        return r.json();
      }));
    }
    return jsonCache.get(path);
  };

  // Array-of-arrays files ({cols, rows}) → array of objects, cached per path.
  var objCache = new Map();
  App.getObjects = function (path) {
    if (!objCache.has(path)) {
      objCache.set(path, App.getJSON(path).then(function (file) {
        return file.rows.map(function (r) {
          var o = {};
          file.cols.forEach(function (c, i) { o[c] = r[i]; });
          return o;
        });
      }));
    }
    return objCache.get(path);
  };

  /* ---------- Chart registry (shared resize + disposal) ---------- */

  var charts = new Set();
  App.chart = function (el) {
    var inst = echarts.init(el, 'wbb', { renderer: 'canvas' });
    charts.add(inst);
    return inst;
  };
  App.clearCharts = function () {
    charts.forEach(function (c) { try { c.dispose(); } catch (e) { /* already gone */ } });
    charts.clear();
  };
  window.addEventListener('resize', function () {
    charts.forEach(function (c) { try { c.resize(); } catch (e) { /* view hidden */ } });
  });

  /* ---------- View registry & hash router ---------- */

  App.views = {};
  App.register = function (name, def) { App.views[name] = def; };

  App.titled = function (main) { return main + ' — Sports Roster Data'; };

  // 'transfers' is parked: its view is built (js/transfers.js, data/transfers.json)
  // but unlinked and unreachable until the previous-school adjudication is done.
  var ROUTES = ['roster', 'player', 'team', 'geography', 'trends', 'about'];

  function parseRoute() {
    var raw = location.hash.replace(/^#/, '') || '/';
    var pathStr = raw.split('?')[0];
    var queryStr = raw.indexOf('?') >= 0 ? raw.slice(raw.indexOf('?') + 1) : '';
    var parts = pathStr.split('/').filter(Boolean);
    var query = {};
    queryStr.split('&').forEach(function (kv) {
      if (!kv) return;
      var eq = kv.indexOf('=');
      var k = eq < 0 ? kv : kv.slice(0, eq);
      var v = eq < 0 ? '' : kv.slice(eq + 1);
      try { query[decodeURIComponent(k)] = decodeURIComponent(v); } catch (e) { query[k] = v; }
    });
    var view = 'home', params = [];
    if (parts.length && ROUTES.indexOf(parts[0]) >= 0) {
      view = parts[0];
      params = parts.slice(1);
    } else if (parts.length) {
      // unknown path → home (hash rewritten so the URL stays clean)
      if (location.hash !== '#/') location.replace('#/');
    }
    return { view: view, params: params, query: query };
  }

  var currentView = null, currentDef = null;

  function updateNav(view) {
    var navView = (view === 'player' || view === 'team') ? 'roster' : view;
    document.querySelectorAll('.site-nav a').forEach(function (a) {
      a.classList.toggle('active', a.dataset.nav === navView);
    });
  }

  function route() {
    var r = parseRoute();
    var def = App.views[r.view];
    var sec = document.getElementById('view-' + r.view);
    if (!def || !sec) {
      if (r.view !== 'home') { location.hash = '#/'; return; }
      def = App.views.home; sec = document.getElementById('view-home');
    }
    if (currentDef && currentDef.cleanup && currentView !== r.view) {
      try { currentDef.cleanup(); } catch (e) { console.error(e); }
    }
    App.clearCharts();

    document.querySelectorAll('.view').forEach(function (el) { el.hidden = true; });
    sec.hidden = false;
    updateNav(r.view);
    document.title = def.title ? def.title(r.params, r.query) : App.titled('Women’s College Basketball Rosters');
    currentView = r.view;
    currentDef = def;
    sec.scrollIntoView({ behavior: 'instant', block: 'start' });
    Promise.resolve(def.render(sec, r.params, r.query)).catch(function (err) {
      console.error(err);
      sec.textContent = '';
      sec.append(App.errorBox(err));
    });
  }

  // Rewrite the current route's query string (filter permalinks) without
  // triggering a hashchange → no re-render, no history entry.
  App.replaceQuery = function (query) {
    var raw = location.hash.replace(/^#/, '') || '/';
    var path = raw.split('?')[0];
    var qs = Object.keys(query)
      .filter(function (k) { return query[k] !== '' && query[k] !== null && query[k] !== undefined; })
      .map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(query[k]); })
      .join('&');
    history.replaceState(null, '', '#' + path + (qs ? '?' + qs : ''));
  };

  /* ---------- Global player search (cross-year) ---------- */

  var playersPromise = null;

  function ensurePlayers() {
    if (!playersPromise) {
      playersPromise = App.getObjects('data/players.json').then(function (list) {
        list.forEach(function (p) { p._l = p.name.toLowerCase(); });
        return list;
      });
    }
    return playersPromise;
  }

  function searchPlayers(players, q) {
    q = q.trim().toLowerCase();
    if (q.length < 2) return [];
    var matches = [];
    for (var i = 0; i < players.length; i++) {
      var p = players[i];
      var l = p._l;
      var score = 0;
      if (l.indexOf(q) === 0) score = 3;                    // starts with the query
      else if (l.indexOf(' ' + q) >= 0) score = 2;         // starts a word (first/last name)
      else if (l.indexOf(q) >= 0) score = 1;               // contains the query
      if (score) matches.push([score, p]);
    }
    matches.sort(function (a, b) {
      return b[0] - a[0] || (b[1].n_seasons - a[1].n_seasons) ||
        (a[1].name < b[1].name ? -1 : a[1].name > b[1].name ? 1 : 0);
    });
    return matches.slice(0, 12).map(function (m) { return m[1]; });
  }

  App.playerSubtitle = function (p) {
    var bits = [];
    if (p.position) bits.push(p.position);
    if (p.height) bits.push(App.fmtHeight(p.height));
    if (p.hometown) bits.push(p.hometown);
    return bits.join(' · ');
  };

  App.seasonSpan = function (firstIdx, lastIdx) {
    var s = App.seasons;
    if (firstIdx === lastIdx) return s[firstIdx];
    return s[firstIdx] + ' – ' + s[lastIdx];
  };

  function initSearch() {
    var input = document.getElementById('global-search');
    var listBox = document.getElementById('search-results');
    var results = [], active = -1;

    input.addEventListener('focus', function () {
      ensurePlayers().catch(function (e) { console.error('Search index failed to load:', e); });
    });

    function close() {
      listBox.hidden = true;
      input.setAttribute('aria-expanded', 'false');
      input.removeAttribute('aria-activedescendant');
      active = -1;
    }

    function open() {
      listBox.hidden = false;
      input.setAttribute('aria-expanded', 'true');
    }

    function choose(p) {
      close();
      input.value = '';
      location.hash = '#/player/' + p.wbb_id;
    }

    function setActive(i) {
      active = i;
      Array.prototype.forEach.call(listBox.children, function (li, j) {
        li.setAttribute('aria-selected', j === i ? 'true' : 'false');
        if (j === i) li.scrollIntoView({ block: 'nearest' });
      });
      var id = i >= 0 ? listBox.children[i].id : null;
      if (id) input.setAttribute('aria-activedescendant', id);
      else input.removeAttribute('aria-activedescendant');
    }

    function render() {
      var q = input.value;
      ensurePlayers().then(function (players) {
        results = searchPlayers(players, q);
        listBox.textContent = '';
        if (!results.length) { close(); return; }
        results.forEach(function (p, i) {
          var li = App.h('li', {
            id: 'sr-opt-' + i, role: 'option', 'aria-selected': 'false',
            onclick: function () { choose(p); },
            onmousedown: function (e) { e.preventDefault(); } // keep focus on the input
          },
            App.h('span', { class: 'sr-name', text: p.name }),
            App.h('span', { class: 'sr-meta', text: App.playerSubtitle(p) }),
            App.h('span', { class: 'sr-meta', text: App.seasonSpan(p.first, p.last) + ' · ' + p.n_seasons + (p.n_seasons === 1 ? ' season' : ' seasons') }));
          listBox.append(li);
        });
        setActive(0);
        open();
      });
    }

    input.addEventListener('input', function () {
      if (input.value.trim().length < 2) { close(); return; }
      render();
    });

    input.addEventListener('keydown', function (e) {
      if (listBox.hidden && (e.key === 'ArrowDown' || e.key === 'ArrowUp') && input.value.trim().length >= 2) {
        render();
        e.preventDefault();
        return;
      }
      if (listBox.hidden) return;
      if (e.key === 'ArrowDown') { e.preventDefault(); setActive(Math.min(active + 1, results.length - 1)); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); setActive(Math.max(active - 1, 0)); }
      else if (e.key === 'Enter') {
        e.preventDefault();
        if (active >= 0 && results[active]) choose(results[active]);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        close();
      }
    });

    document.addEventListener('click', function (e) {
      if (!listBox.hidden && !listBox.contains(e.target) && e.target !== input) close();
    });
  }

  /* ---------- Home view ---------- */

  // US map GeoJSON is registered once and shared by the home tile and the
  // geography page.
  var mapRegistered = false;
  App.registerUSMap = function (geojson) {
    if (!mapRegistered) { echarts.registerMap('USA', geojson); mapRegistered = true; }
  };

  var HOME_YEAR_ORDER = ['Freshman', 'Sophomore', 'Junior', 'Senior', 'Graduate Student',
    'Fifth Year', 'Sixth Year', 'Unknown'];
  var homeToken = 0;

  function svgEl(tag, attrs) {
    var el = document.createElementNS('http://www.w3.org/2000/svg', tag);
    Object.keys(attrs).forEach(function (k) {
      if (k === 'text') el.textContent = attrs[k]; else el.setAttribute(k, attrs[k]);
    });
    return el;
  }

  // Thumbnail timeline for the featured player: one dot per season, a new
  // colour each time the team changes, team labels above the line.
  function homeTimeline(box, player) {
    box.textContent = '';
    var path = player.seasons.map(function (sx) {
      return Array.isArray(sx) ? { idx: sx[0], team: sx[1] } : sx;
    });
    var n = path.length;
    if (!n) return;
    var W = 240, H = 100, x0 = 22, x1 = W - 22;
    var svg = svgEl('svg', { viewBox: '0 0 ' + W + ' ' + H, preserveAspectRatio: 'xMidYMid meet' });
    var xs = path.map(function (_, i) { return n === 1 ? W / 2 : x0 + (x1 - x0) * i / (n - 1); });
    svg.append(svgEl('line', { x1: xs[0], y1: 62, x2: xs[n - 1], y2: 62, stroke: '#bfdbfe', 'stroke-width': 3, 'stroke-linecap': 'round' }));
    var stint = -1, lastTeam = null;
    path.forEach(function (p, i) {
      if (p.team !== lastTeam) {
        stint += 1; lastTeam = p.team;
        var runEnd = i;
        while (runEnd + 1 < n && path[runEnd + 1].team === p.team) runEnd += 1;
        var cx = (xs[i] + xs[runEnd]) / 2;
        var label = p.team.length > 16 ? p.team.slice(0, 15) + '…' : p.team;
        // Edge stints anchor inward so long names stay inside the viewBox.
        var anchor = cx < 50 ? 'start' : cx > W - 50 ? 'end' : 'middle';
        var tx = anchor === 'start' ? Math.max(4, xs[i] - 8) : anchor === 'end' ? Math.min(W - 4, xs[runEnd] + 8) : cx;
        // Alternate label rows so short back-to-back stints don't collide.
        svg.append(svgEl('text', { x: tx, y: stint % 2 ? 32 : 46, 'font-size': 10, 'font-weight': 600,
          'text-anchor': anchor, fill: App.palette[stint % App.palette.length], text: label }));
      }
      svg.append(svgEl('circle', { cx: xs[i], cy: 62, r: 6.5, fill: App.palette[stint % App.palette.length], stroke: '#fff', 'stroke-width': 2 }));
      svg.append(svgEl('text', { x: xs[i], y: 86, 'font-size': 9, 'text-anchor': 'middle', fill: '#78716c',
        text: (App.seasons[p.idx] || '').replace(/^20/, '') }));
    });
    svg.append(svgEl('text', { x: W / 2, y: 14, 'font-size': 11, 'text-anchor': 'middle', fill: '#1c1917', 'font-weight': 600, text: player.name }));
    box.append(svg);
  }

  function homeStatic() {
    var meta = App.meta;
    var sec = document.getElementById('view-home');
    if (sec.dataset.built) return;
    sec.dataset.built = '1';

    var title = document.getElementById('home-title');
    title.textContent = 'Every NCAA women’s basketball roster since ' + meta.seasons[0];

    var stats = { player_seasons: meta.player_seasons, players: meta.players, teams: meta.teams,
      seasons: meta.seasons.length, countries: meta.countries };
    sec.querySelectorAll('[data-stat]').forEach(function (el) {
      var v = stats[el.dataset.stat];
      el.textContent = v === undefined ? '—' : App.fmtNum(v);
    });
    document.getElementById('home-stat-players').addEventListener('click', function (e) {
      e.preventDefault();
      document.getElementById('global-search').focus();
    });

    // Roster thumb: three real filter values (first non-Unknown of each list).
    var fo = meta.filter_options || {};
    function firstReal(list) {
      return (list || []).filter(function (v) { return v !== 'Unknown'; })[0];
    }
    var chips = document.getElementById('home-roster-chips');
    [firstReal(fo.conference), 'Guard', firstReal(fo.year)].forEach(function (v) {
      if (v) chips.append(App.h('span', { class: 'chip filter-chip', text: v }));
    });

    // Downloads thumb: the latest season's file name.
    var last = meta.seasons[meta.seasons.length - 1];
    document.getElementById('home-file-a').textContent = 'wbb_rosters';
    document.getElementById('home-file-b').textContent = '_' + last.replace(/-/g, '_') + '.csv';

    // Featured multi-team players (meta.featured_players), timeline from the first.
    var featured = meta.featured_players || [];
    var row = document.getElementById('home-featured');
    featured.forEach(function (p) {
      row.append(App.h('a', { class: 'chip', href: '#/player/' + p.wbb_id, text: p.name }));
    });
    if (featured.length) homeTimeline(document.getElementById('home-timeline'), featured[0]);

    var link = document.getElementById('home-search-link');
    link.addEventListener('click', function (e) {
      e.preventDefault();
      document.getElementById('global-search').focus();
    });
  }

  // Non-interactive mini charts for the Geography and Trends tiles. Charts are
  // disposed by App.clearCharts() on every route change, so they are rebuilt
  // on each home render; a missing data file leaves the tile blank.
  function homeCharts() {
    var token = ++homeToken;
    var mapEl = document.getElementById('home-map');
    var classEl = document.getElementById('home-class');

    App.getJSON('data/trends.json').then(function (tr) {
      if (token !== homeToken) return;
      var inst = App.chart(classEl);
      inst.setOption({
        animation: false, silent: true,
        grid: { left: 6, right: 6, top: 6, bottom: 6 },
        xAxis: { type: 'category', data: App.seasons, show: false },
        yAxis: { type: 'value', show: false },
        series: HOME_YEAR_ORDER.filter(function (k) { return tr.class_season[k]; }).map(function (key, i) {
          return { name: key, type: 'bar', stack: 'total', barWidth: '55%',
            itemStyle: { color: App.palette[i], borderColor: '#ffffff', borderWidth: 1, borderRadius: 2 },
            data: tr.class_season[key] };
        })
      });
    }).catch(function (err) { console.warn('home trends tile', err); });

    Promise.all([App.getJSON('data/geography.json'), App.getJSON('data/us-states.json')]).then(function (res) {
      if (token !== homeToken) return;
      var geo = res[0];
      App.registerUSMap(res[1]);
      var statesMeta = App.meta.states;
      var rows = [], maxV = 0;
      Object.keys(geo.state_season).forEach(function (code) {
        var st = statesMeta[code];
        if (!st || !st.pop) return;
        var count = geo.state_season[code].reduce(function (a, b) { return a + b; }, 0);
        var v = count / st.pop * 1e6;
        maxV = Math.max(maxV, v);
        rows.push({ name: st.name, value: v });
      });
      var inst = App.chart(mapEl);
      inst.setOption({
        animation: false, silent: true,
        visualMap: { show: false, min: 0, max: maxV, inRange: { color: App.seqRamp }, outOfRange: { color: App.noData } },
        // Lower 48 only: at thumbnail size Alaska would swallow the frame.
        series: [{ type: 'map', map: 'USA', data: rows, selectedMode: false, roam: false,
          boundingCoords: [[-125, 49.5], [-66.5, 24.5]],
          top: 2, bottom: 2, left: 2, right: 2,
          itemStyle: { borderColor: '#ffffff', borderWidth: 0.6 },
          emphasis: { disabled: true } }]
      });
    }).catch(function (err) { console.warn('home map tile', err); });
  }

  App.register('home', {
    title: function () {
      return 'Women’s College Basketball Rosters — Sports Roster Data';
    },
    render: function () {
      homeStatic();
      homeCharts();
      return Promise.resolve();
    }
  });

  /* ---------- About view (static prose; downloads built from meta) ---------- */

  var REPO = 'https://github.com/Sports-Roster-Data/womens-college-basketball';

  App.register('about', {
    title: function () { return App.titled('About'); },
    render: function (sec) {
      var list = document.getElementById('about-downloads');
      if (!list.dataset.built) {
        list.dataset.built = '1';
        var files = [];
        App.meta.seasons.forEach(function (season) {
          files.push(['wbb_rosters_' + season.replace(/-/g, '_') + '.csv',
            'Roster for ' + season + ' — one row per player']);
        });
        files.push(['wbb_rosters_combined.csv', 'Every season combined, with the cross-season wbb_id joined on']);
        files.push(['players.csv', 'One row per player: wbb_id, seasons played, mode height/position/hometown, match confidence']);
        files.push(['wbb_player_seasons.csv', 'One row per player-season: the season-level links between the two files above']);
        files.push(['teams.csv', 'Team metadata — ncaa_id is the join key used everywhere']);
        files.forEach(function (f) {
          list.append(App.h('li', {},
            App.h('a', { class: 'dl-file', href: REPO + '/blob/main/' + f[0] }, f[0]),
            App.h('span', { class: 'note', text: f[1] })));
        });
      }
      return Promise.resolve();
    }
  });

  /* ---------- Start ---------- */

  function start() {
    App.getJSON('data/meta.json').then(function (meta) {
      App.meta = meta;
      App.seasons = meta.seasons;
      initSearch();
      window.addEventListener('hashchange', route);
      route();
    }).catch(function (err) {
      console.error(err);
      var home = document.getElementById('view-home');
      home.textContent = '';
      home.append(App.errorBox('Site data not found (data/meta.json). This site is generated from the repository’s CSVs — run scripts/build_site_data.R first (see site/README.md), then reload.'));
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();