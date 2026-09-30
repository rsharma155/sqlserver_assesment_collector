/**
 * Thin facade over ServerConfigRules for the sizing UI.
 */
window.ServerSizing = (() => {
  function fromForm(formData) {
    return window.ServerConfigRules.sizeServer({
      marketProfile: formData.marketProfile,
      appType: formData.appType,
      transactionsPerDay: formData.transactionsPerDay,
      activeUsersRange: formData.activeUsersRange,
      tablesRange: formData.tablesRange,
      currentDbSizeRange: formData.currentDbSizeRange,
      estimatedDbSizeRange: formData.estimatedDbSizeRange,
      dailyInsertGb: formData.dailyInsertGb,
      monthlyInsertGb: formData.monthlyInsertGb,
      criticality: formData.criticality,
      rpoMinutes: formData.rpoMinutes,
      dbEngine: formData.dbEngine,
      appAbout: formData.appAbout,
    });
  }

  function suggestDbConfigFromSizing(result) {
    const rec = result.recommendation;
    const hardware = {
      vcpu: rec.vcpu,
      ramGb: rec.ramGb,
      storageGb: rec.storageGb,
      storageType: rec.storageType.toLowerCase().includes('nvme')
        ? 'nvme'
        : rec.storageType.toLowerCase().includes('hdd')
          ? 'hdd'
          : 'ssd',
      cpuType: 'general',
      numaNodes: rec.vcpu >= 16 ? 2 : 1,
      workload: mapAppToWorkload(result.app.id),
    };

    const out = { hardware, sql: null, postgres: null };
    if (rec.dbEngine === 'sqlserver' || rec.dbEngine === 'both') {
      out.sql = window.SqlServerConfig.recommend(hardware);
    }
    if (rec.dbEngine === 'postgres' || rec.dbEngine === 'both') {
      out.postgres = window.PostgresConfig.recommend(hardware);
    }
    return out;
  }

  function mapAppToWorkload(appId) {
    if (appId === 'reporting' || appId === 'batch') return 'reporting';
    if (appId === 'mixed') return 'mixed';
    return 'oltp';
  }

  return { fromForm, suggestDbConfigFromSizing, mapAppToWorkload };
})();
