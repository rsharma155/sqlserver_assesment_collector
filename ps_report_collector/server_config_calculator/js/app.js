(() => {
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function fillSelect(selectEl, options, selectedValue) {
    if (!selectEl) return;
    selectEl.innerHTML = options
      .map((o) => `<option value="${escapeHtml(o.value)}">${escapeHtml(o.label)}</option>`)
      .join('');
    if (selectedValue) selectEl.value = selectedValue;
  }

  function initTabs() {
    $$('.tab-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        $$('.tab-btn').forEach((b) => b.classList.toggle('active', b === btn));
        $$('.tab-panel').forEach((p) => p.classList.toggle('active', p.id === btn.dataset.tab));
      });
    });
  }

  /** Show/hide engine-specific fields (NUMA = SQL Server; max connections = Postgres). */
  function syncConfigEngineFields() {
    const engine = $('#hwEngine')?.value || 'both';
    $$('#configForm [data-show-for]').forEach((field) => {
      const allowed = (field.dataset.showFor || '')
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
      field.classList.toggle('is-hidden', !allowed.includes(engine));
    });
  }

  function initEngineFieldToggle() {
    const engine = $('#hwEngine');
    if (!engine) return;
    engine.addEventListener('change', syncConfigEngineFields);
    syncConfigEngineFields();
  }

  function populateMarketProfiles() {
    const select = $('#szMarket');
    const profiles = window.ServerConfigRules.MARKET_PROFILES;
    select.innerHTML = Object.values(profiles)
      .map((m) => `<option value="${m.id}">${escapeHtml(m.label)}</option>`)
      .join('');
    select.value = 'local';
    updateMarketHelp();
    select.addEventListener('change', updateMarketHelp);
  }

  function updateMarketHelp() {
    const market = window.ServerConfigRules.MARKET_PROFILES[$('#szMarket').value];
    $('#marketHelp').textContent = market ? market.description : '';
  }

  function populateAppTypes() {
    const select = $('#appType');
    const rules = window.ServerConfigRules.APP_TYPES;
    select.innerHTML = Object.values(rules)
      .map((a) => `<option value="${a.id}">${a.label}</option>`)
      .join('');
    select.value = 'oltp';
    updateAppTypeHelp();
    select.addEventListener('change', updateAppTypeHelp);
  }

  function updateAppTypeHelp() {
    const app = window.ServerConfigRules.APP_TYPES[$('#appType').value];
    $('#appTypeHelp').textContent = app ? app.description : '';
  }

  function populateSizingDropdowns() {
    const opts = window.ServerConfigRules.INPUT_OPTIONS;
    fillSelect($('#szTxnDay'), opts.transactionsPerDay, '5k-10k');
    fillSelect($('#szActiveUsers'), opts.activeUsers, '25-50');
    fillSelect($('#szTablesRange'), opts.tables, '50-100');
    fillSelect($('#szCurrentDb'), opts.dbSizeGb, '20-50');
    fillSelect($('#szEstimatedDb'), opts.dbSizeGb, '50-100');
  }

  function num(id) {
    const v = $(id).value;
    return v === '' ? NaN : Number(v);
  }

  function readHardwareForm() {
    const engine = $('#hwEngine').value;
    const numaFieldVisible = !$('#fieldNuma')?.classList.contains('is-hidden');
    const maxConnVisible = !$('#fieldMaxConn')?.classList.contains('is-hidden');
    return {
      vcpu: num('#hwVcpu'),
      ramGb: num('#hwRam'),
      storageGb: num('#hwStorage'),
      storageType: $('#hwStorageType').value,
      cpuType: $('#hwCpuType').value,
      numaNodes: numaFieldVisible ? num('#hwNuma') || 1 : 1,
      workload: $('#hwWorkload').value,
      maxConnections: maxConnVisible ? num('#hwMaxConn') || 0 : 0,
      sqlEdition: $('#hwSqlEdition')?.value || 'enterprise',
      sqlInstances: num('#hwSqlInstances') || 1,
      otherServicesGb: num('#hwOtherServices') || 0,
      alwaysOnReadable: $('#hwAlwaysOn')?.value === 'yes',
      engine,
    };
  }

  function renderSettingsTable(settings) {
    return `
      <table class="data-table">
        <thead><tr><th>Setting</th><th>Recommended</th><th>Why</th></tr></thead>
        <tbody>
          ${settings
            .map(
              (s) => `<tr>
                <td><code>${escapeHtml(s.name)}</code></td>
                <td><strong>${escapeHtml(s.value)}</strong></td>
                <td>${escapeHtml(s.why)}</td>
              </tr>`
            )
            .join('')}
        </tbody>
      </table>`;
  }

  function htmlSqlCard(sql) {
    return `
      <section class="result-card">
        <div class="result-card-head">
          <h3>SQL Server recommendations</h3>
          <span class="badge">Best practice</span>
        </div>
        <div class="kpi-row">
          <div class="kpi"><span class="kpi-label">Max memory</span><span class="kpi-value">${sql.summary.maxServerMemoryMb} MB</span></div>
          <div class="kpi"><span class="kpi-label">MAXDOP</span><span class="kpi-value">${sql.summary.maxDop}</span></div>
          <div class="kpi"><span class="kpi-label">TempDB files</span><span class="kpi-value">${sql.summary.tempdbFiles}</span></div>
          <div class="kpi"><span class="kpi-label">OS reserve</span><span class="kpi-value">${sql.summary.osReserveGb} GB</span></div>
        </div>
        ${renderSettingsTable(sql.settings)}
        <h4>Notes</h4>
        <ul class="notes">${sql.instanceHints.map((h) => `<li>${escapeHtml(h)}</li>`).join('')}</ul>
        <h4>Starter T-SQL</h4>
        <pre class="code-block"><code>${escapeHtml(sql.tsql)}</code></pre>
      </section>`;
  }

  function htmlPostgresCard(postgres) {
    return `
      <section class="result-card">
        <div class="result-card-head">
          <h3>PostgreSQL recommendations</h3>
          <span class="badge">Best practice</span>
        </div>
        <div class="kpi-row">
          <div class="kpi"><span class="kpi-label">shared_buffers</span><span class="kpi-value">${escapeHtml(postgres.summary.sharedBuffers)}</span></div>
          <div class="kpi"><span class="kpi-label">effective_cache</span><span class="kpi-value">${escapeHtml(postgres.summary.effectiveCacheSize)}</span></div>
          <div class="kpi"><span class="kpi-label">work_mem</span><span class="kpi-value">${escapeHtml(postgres.summary.workMem)}</span></div>
          <div class="kpi"><span class="kpi-label">max_connections</span><span class="kpi-value">${postgres.summary.maxConnections}</span></div>
        </div>
        ${renderSettingsTable(postgres.settings)}
        <h4>Notes</h4>
        <ul class="notes">${postgres.instanceHints.map((h) => `<li>${escapeHtml(h)}</li>`).join('')}</ul>
        <h4>Starter postgresql.conf</h4>
        <pre class="code-block"><code>${escapeHtml(postgres.conf)}</code></pre>
      </section>`;
  }

  function renderConfigResult(sql, postgres) {
    let html = '';
    if (sql) html += htmlSqlCard(sql);
    if (postgres) html += htmlPostgresCard(postgres);
    $('#configResults').innerHTML = html || '<p class="muted">Choose an engine and click Calculate.</p>';
  }

  function onCalculateConfig(e) {
    e.preventDefault();
    const hw = readHardwareForm();
    if (!hw.vcpu || !hw.ramGb) {
      alert('Please enter vCPU and RAM.');
      return;
    }
    let sql = null;
    let postgres = null;
    if (hw.engine === 'sqlserver' || hw.engine === 'both') sql = window.SqlServerConfig.recommend(hw);
    if (hw.engine === 'postgres' || hw.engine === 'both') postgres = window.PostgresConfig.recommend(hw);
    renderConfigResult(sql, postgres);
    $('#configResults').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function readSizingForm() {
    return {
      marketProfile: $('#szMarket').value,
      appType: $('#appType').value,
      appAbout: $('#appAbout').value.trim(),
      transactionsPerDay: $('#szTxnDay').value,
      activeUsersRange: $('#szActiveUsers').value,
      tablesRange: $('#szTablesRange').value,
      currentDbSizeRange: $('#szCurrentDb').value,
      estimatedDbSizeRange: $('#szEstimatedDb').value,
      dailyInsertGb: num('#szDailyGb'),
      monthlyInsertGb: num('#szMonthlyGb'),
      criticality: $('#szCriticality').value,
      rpoMinutes: num('#szRpo'),
      dbEngine: $('#szEngine').value,
    };
  }

  function renderSizingResult(result, dbConfigs) {
    const r = result.recommendation;
    const about = $('#appAbout').value.trim();
    const summary = result.inputSummary || {};

    let html = `
      <section class="result-card highlight">
        <div class="result-card-head">
          <h3>Recommended server</h3>
          <span class="badge tier-${result.tier}">${escapeHtml(r.serverType)}</span>
        </div>
        ${about ? `<p class="app-about">${escapeHtml(about)}</p>` : ''}
        <p class="muted" style="margin:0 0 0.75rem">Market: <strong>${escapeHtml(r.marketProfile || result.market.label)}</strong></p>
        <div class="kpi-row">
          <div class="kpi"><span class="kpi-label">vCPU</span><span class="kpi-value">${r.vcpu}</span></div>
          <div class="kpi"><span class="kpi-label">RAM</span><span class="kpi-value">${r.ramGb} GB</span></div>
          <div class="kpi"><span class="kpi-label">Storage</span><span class="kpi-value">${r.storageGb} GB</span></div>
          <div class="kpi"><span class="kpi-label">Network</span><span class="kpi-value">${escapeHtml(r.networkLabel)}</span></div>
        </div>
        <table class="data-table">
          <tbody>
            <tr><th>Server type</th><td>${escapeHtml(r.serverType)} — ${escapeHtml(result.tierDescription)}</td></tr>
            <tr><th>Storage type</th><td>${escapeHtml(r.storageType)} (${escapeHtml(r.storageIopsHint)})</td></tr>
            <tr><th>Network class</th><td>${escapeHtml(r.networkLabel)} (~${r.networkMbps} Mbps class)</td></tr>
            <tr><th>HADR</th><td><strong>${escapeHtml(r.hadrLevel)}</strong><br><span class="muted">${escapeHtml(r.hadrDetail)}</span></td></tr>
            <tr><th>Workload score</th><td>${result.workload.score}/100</td></tr>
            <tr><th>Current vs estimated DB</th><td>~${r.currentDbGb} GB current → ~${r.estimatedDbGb} GB estimated start</td></tr>
            <tr><th>Projected data (planning)</th><td>~${r.projectedAnnualDataGb} GB (before indexes/headroom in storage pick)</td></tr>
            <tr><th>App type</th><td>${escapeHtml(result.app.label)}</td></tr>
            <tr><th>Inputs used</th><td>
              Txn/day: ${escapeHtml(summary.transactionsPerDay || 'n/a')}; 
              Active users: ${escapeHtml(summary.activeUsers || 'n/a')}; 
              Tables: ${escapeHtml(summary.tables || 'n/a')}
            </td></tr>
          </tbody>
        </table>
        <h4>Rationale</h4>
        <ul class="notes">${result.rationale.map((x) => `<li>${escapeHtml(x)}</li>`).join('')}</ul>
        <h4>Formulas used</h4>
        <ul class="notes">
          ${Object.entries(result.formulas)
            .map(([k, v]) => `<li><code>${escapeHtml(k)}</code>: ${escapeHtml(v)}</li>`)
            .join('')}
        </ul>
      </section>`;

    if (dbConfigs.sql || dbConfigs.postgres) {
      html += `<div class="section-divider"><h3>Matching DB configuration for this server</h3></div>`;
      if (dbConfigs.sql) html += htmlSqlCard(dbConfigs.sql);
      if (dbConfigs.postgres) html += htmlPostgresCard(dbConfigs.postgres);
    }

    $('#sizingResults').innerHTML = html;
  }

  function onCalculateSizing(e) {
    e.preventDefault();
    const form = readSizingForm();
    if (!form.marketProfile || !form.transactionsPerDay || !form.activeUsersRange) {
      alert('Please select market, transactions/day, and active users.');
      return;
    }
    const result = window.ServerSizing.fromForm(form);
    const dbConfigs = window.ServerSizing.suggestDbConfigFromSizing(result);
    renderSizingResult(result, dbConfigs);
    $('#sizingResults').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function exportSizingJson() {
    const form = readSizingForm();
    const result = window.ServerSizing.fromForm(form);
    const dbConfigs = window.ServerSizing.suggestDbConfigFromSizing(result);
    const blob = new Blob([JSON.stringify({ form, result, dbConfigs }, null, 2)], {
      type: 'application/json',
    });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `server-sizing-${result.tier}-${Date.now()}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
  }

  function init() {
    initTabs();
    initEngineFieldToggle();
    populateMarketProfiles();
    populateAppTypes();
    populateSizingDropdowns();
    $('#configForm').addEventListener('submit', onCalculateConfig);
    $('#sizingForm').addEventListener('submit', onCalculateSizing);
    $('#exportSizingBtn')?.addEventListener('click', exportSizingJson);

    // Local mid-market defaults for hardware tuner
    $('#hwVcpu').value = 8;
    $('#hwRam').value = 32;
    $('#hwStorage').value = 512;
  }

  document.addEventListener('DOMContentLoaded', init);
})();
