/**
 * Predefined market profiles, application-type rules, and sizing formulas.
 * Local mid-market defaults target 8–16 cores, 32–64 GB RAM, 512 GB–1 TB SSD.
 */
window.ServerConfigRules = (() => {
  /** @typedef {'starter'|'standard'|'upper'|'growth'} Tier */

  /**
   * Market reach profiles. Local market is the default for mid-sized companies
   * with light–moderate OLTP (&lt; ~10k row transactions/day).
   */
  const MARKET_PROFILES = {
    local: {
      id: 'local',
      label: 'Local market (mid-sized)',
      description:
        'Typical SME / local deployments: light–moderate OLTP, daily transactions usually under ~10k rows. Hardware commonly 8–16 cores, 32–64 GB RAM, 512 GB–1 TB SSD.',
      maxVcpu: 16,
      maxRamGb: 64,
      maxStorageGb: 1024,
      scoreScale: 1.0,
      networkClass: '1 GbE',
      notes: [
        'Sized for local mid-market hardware budgets (not hyperscale cloud SKUs).',
        'Prefer a single well-tuned primary + solid backups over complex multi-node HADR unless criticality demands it.',
        'SSD (SATA/NVMe) is assumed; HDD is not recommended for the database volume.',
      ],
    },
    regional: {
      id: 'regional',
      label: 'Regional / growing',
      description:
        'Growing regional apps or multi-branch businesses: higher concurrency and storage headroom. Caps around 24 cores / 96 GB / 2 TB.',
      maxVcpu: 24,
      maxRamGb: 96,
      maxStorageGb: 2048,
      scoreScale: 1.15,
      networkClass: '1–2 GbE',
      notes: [
        'Allows modest growth above typical local hardware without jumping to enterprise SKUs.',
        'Consider a readable async replica if reporting competes with OLTP.',
      ],
    },
    enterprise: {
      id: 'enterprise',
      label: 'Enterprise / high-scale',
      description:
        'High concurrency, heavy analytics, or cloud-scale workloads. Unlocks larger tiers (32+ cores, 128+ GB).',
      maxVcpu: 64,
      maxRamGb: 512,
      maxStorageGb: 10240,
      scoreScale: 1.35,
      networkClass: '10 GbE class',
      notes: [
        'Use when local mid-market caps are clearly insufficient (heavy reporting, SaaS multi-tenant, telemetry).',
        'Validate with load tests and licensing (SQL Server core packs).',
      ],
    },
  };

  /** Dropdown option catalogs for the sizing form. */
  const INPUT_OPTIONS = {
    transactionsPerDay: [
      { value: 'lt1k', label: '< 1,000 / day', midpoint: 500 },
      { value: '1k-5k', label: '1,000 – 5,000 / day', midpoint: 3000 },
      { value: '5k-10k', label: '5,000 – 10,000 / day', midpoint: 7500 },
      { value: '10k-50k', label: '10,000 – 50,000 / day', midpoint: 25000 },
      { value: '50k-plus', label: '50,000+ / day', midpoint: 100000 },
    ],
    activeUsers: [
      { value: 'lt10', label: '< 10 active', midpoint: 5 },
      { value: '10-25', label: '10 – 25 active', midpoint: 18 },
      { value: '25-50', label: '25 – 50 active', midpoint: 40 },
      { value: '50-100', label: '50 – 100 active', midpoint: 75 },
      { value: '100-250', label: '100 – 250 active', midpoint: 175 },
      { value: '250-plus', label: '250+ active', midpoint: 400 },
    ],
    tables: [
      { value: 'lt50', label: '< 50 tables', midpoint: 30 },
      { value: '50-100', label: '50 – 100 tables', midpoint: 75 },
      { value: '100-250', label: '100 – 250 tables', midpoint: 175 },
      { value: '250-500', label: '250 – 500 tables', midpoint: 375 },
      { value: '500-plus', label: '500+ tables', midpoint: 750 },
    ],
    dbSizeGb: [
      { value: 'lt5', label: '< 5 GB', midpoint: 2 },
      { value: '5-20', label: '5 – 20 GB', midpoint: 12 },
      { value: '20-50', label: '20 – 50 GB', midpoint: 35 },
      { value: '50-100', label: '50 – 100 GB', midpoint: 75 },
      { value: '100-250', label: '100 – 250 GB', midpoint: 175 },
      { value: '250-500', label: '250 – 500 GB', midpoint: 375 },
      { value: '500-plus', label: '500+ GB', midpoint: 750 },
    ],
  };

  const APP_TYPES = {
    oltp: {
      id: 'oltp',
      label: 'OLTP / Transactional',
      description: 'High concurrency, short transactions, frequent reads/writes (ERP, booking, banking).',
      cpuWeight: 1.15,
      ramWeight: 1.1,
      storageWeight: 1.0,
      iopsWeight: 1.25,
      networkWeight: 1.0,
      hadrBias: 'medium',
      storageProfile: 'ssd_standard',
      notes: [
        'Prioritize low-latency SSD and enough RAM for buffer cache.',
        'Keep MaxDOP moderate (OLTP-friendly) after sizing hardware.',
      ],
    },
    ecommerce: {
      id: 'ecommerce',
      label: 'E-commerce / Retail',
      description: 'Bursty traffic, catalog reads, order writes, seasonal peaks.',
      cpuWeight: 1.2,
      ramWeight: 1.15,
      storageWeight: 1.05,
      iopsWeight: 1.2,
      networkWeight: 1.25,
      hadrBias: 'medium',
      storageProfile: 'ssd_premium',
      notes: [
        'Size for peak (events/sales), not only average daily load.',
        'Cache/CDN offload reduces DB pressure on catalog reads.',
      ],
    },
    saas: {
      id: 'saas',
      label: 'SaaS / Multi-tenant',
      description: 'Many tenants, mixed workloads, growth-oriented concurrency.',
      cpuWeight: 1.2,
      ramWeight: 1.25,
      storageWeight: 1.15,
      iopsWeight: 1.15,
      networkWeight: 1.1,
      hadrBias: 'high',
      storageProfile: 'ssd_premium',
      notes: [
        'RAM grows with tenant count and connection pooling needs.',
        'Prefer connection poolers (PgBouncer / proxy).',
      ],
    },
    reporting: {
      id: 'reporting',
      label: 'Reporting / Analytics',
      description: 'Heavy reads, large scans, periodic ETL into warehouse-style schemas.',
      cpuWeight: 1.3,
      ramWeight: 1.35,
      storageWeight: 1.4,
      iopsWeight: 1.05,
      networkWeight: 1.05,
      hadrBias: 'medium',
      storageProfile: 'ssd_throughput',
      notes: [
        'More CPU/RAM for parallel query; storage capacity matters.',
        'Prefer a replica for heavy reports when possible.',
      ],
    },
    mixed: {
      id: 'mixed',
      label: 'Mixed OLTP + Reporting',
      description: 'Same database serves transactions and operational reports.',
      cpuWeight: 1.25,
      ramWeight: 1.25,
      storageWeight: 1.2,
      iopsWeight: 1.2,
      networkWeight: 1.1,
      hadrBias: 'medium',
      storageProfile: 'ssd_premium',
      notes: [
        'Isolate reporting via replicas when possible.',
        'Watch tempdb / work_mem under concurrent analytical queries.',
      ],
    },
    iot: {
      id: 'iot',
      label: 'IoT / Telemetry / Logging',
      description: 'High insert rate, append-heavy, time-series retention.',
      cpuWeight: 1.1,
      ramWeight: 1.0,
      storageWeight: 1.5,
      iopsWeight: 1.35,
      networkWeight: 1.2,
      hadrBias: 'low',
      storageProfile: 'ssd_throughput',
      notes: [
        'Storage growth and ingest IOPS dominate sizing.',
        'Partition by time; define retention/archival early.',
      ],
    },
    cms: {
      id: 'cms',
      label: 'CMS / Content Platform',
      description: 'Read-heavy content, moderate writes, media metadata.',
      cpuWeight: 0.95,
      ramWeight: 1.0,
      storageWeight: 1.1,
      iopsWeight: 0.9,
      networkWeight: 1.05,
      hadrBias: 'low',
      storageProfile: 'ssd_standard',
      notes: [
        'Cache layers (CDN/Redis) reduce DB load significantly.',
        'DB mainly stores metadata; media often offloaded to object storage.',
      ],
    },
    batch: {
      id: 'batch',
      label: 'Batch / ETL / Integration',
      description: 'Scheduled bulk loads, transformations, overnight jobs.',
      cpuWeight: 1.2,
      ramWeight: 1.15,
      storageWeight: 1.35,
      iopsWeight: 1.25,
      networkWeight: 1.1,
      hadrBias: 'low',
      storageProfile: 'ssd_throughput',
      notes: [
        'Size for job windows (CPU + throughput disk).',
        'HADR optional if jobs are restartable and backups are solid.',
      ],
    },
  };

  /**
   * Local-market-first tiers. Upper local ≈ 16 cores / 64 GB / 1 TB SSD.
   * Growth tier is only used when market profile allows (regional/enterprise).
   */
  const TIER_SPECS = {
    starter: {
      label: 'Starter',
      vcpu: 4,
      ramGb: 16,
      storageGb: 256,
      networkMbps: 1000,
      description: 'Dev/test or very light production (few users, tiny DB).',
    },
    standard: {
      label: 'Standard (local mid)',
      vcpu: 8,
      ramGb: 32,
      storageGb: 512,
      networkMbps: 1000,
      description: 'Typical local mid-sized production: modest concurrency, &lt;10k txn/day.',
    },
    upper: {
      label: 'Upper local',
      vcpu: 16,
      ramGb: 64,
      storageGb: 1024,
      networkMbps: 2000,
      description: 'Top of common local hardware: busier OLTP or larger working set.',
    },
    growth: {
      label: 'Growth',
      vcpu: 24,
      ramGb: 96,
      storageGb: 2048,
      networkMbps: 5000,
      description: 'Beyond typical local boxes — regional growth or heavier analytics.',
    },
  };

  const STORAGE_PROFILES = {
    ssd_standard: { label: 'SSD (General Purpose)', iopsHint: '3k–10k IOPS', latency: 'low' },
    ssd_premium: { label: 'Premium SSD / NVMe', iopsHint: '10k–40k+ IOPS', latency: 'very low' },
    ssd_throughput: { label: 'Throughput-optimized SSD', iopsHint: 'high sequential MB/s', latency: 'low' },
    hdd: { label: 'HDD (not recommended for DB)', iopsHint: '<500 IOPS', latency: 'high' },
  };

  function optionMidpoint(catalog, value, fallback) {
    const hit = (INPUT_OPTIONS[catalog] || []).find((o) => o.value === value);
    return hit ? hit.midpoint : fallback;
  }

  function optionLabel(catalog, value) {
    const hit = (INPUT_OPTIONS[catalog] || []).find((o) => o.value === value);
    return hit ? hit.label : value || 'n/a';
  }

  /**
   * Resolve form dropdowns (or legacy numeric fields) into concrete workload numbers.
   */
  function resolveWorkloadInputs(input) {
    const activeUsers =
      Number(input.activeUsers) ||
      optionMidpoint('activeUsers', input.activeUsersRange, 0) ||
      Number(input.concurrentUsers) ||
      Math.max(1, Math.ceil((Number(input.users) || 0) * 0.1));

    const dailyTxnRows =
      Number(input.dailyTransactions) ||
      optionMidpoint('transactionsPerDay', input.transactionsPerDay, 0) ||
      Number(input.dailyInsertRows) ||
      0;

    const tables =
      Number(input.tables) || optionMidpoint('tables', input.tablesRange, 0) || 0;

    const currentDbGb =
      Number(input.currentDbSizeGb) ||
      optionMidpoint('dbSizeGb', input.currentDbSizeRange, 0) ||
      0;

    const estimatedDbGb =
      Number(input.estimatedDbSizeGb) ||
      optionMidpoint('dbSizeGb', input.estimatedDbSizeRange, 0) ||
      currentDbGb;

    // Prefer explicit estimated size; fall back to current; else light growth from txn volume.
    const planningDbGb = Math.max(estimatedDbGb, currentDbGb, dailyTxnRows > 0 ? dailyTxnRows / 50000 : 1);

    // Rough monthly ingest for storage projection when GB/day not provided.
    const dailyInsertGb =
      Number(input.dailyInsertGb) ||
      (dailyTxnRows > 0 ? Math.max(0.01, dailyTxnRows * 0.000002) : 0); // ~2 KB/row avg
    const weeklyGb = Number(input.weeklyInsertGb) || dailyInsertGb * 7;
    const monthlyGb = Number(input.monthlyInsertGb) || weeklyGb * 4.3;

    return {
      activeUsers,
      dailyTxnRows,
      tables,
      currentDbGb,
      estimatedDbGb,
      planningDbGb,
      dailyInsertGb,
      weeklyGb,
      monthlyGb,
    };
  }

  /**
   * Score workload 0–100. Calibrated so local mid-market (&lt;10k txn/day, tens of users)
   * lands in starter–upper, not enterprise x-large.
   */
  function computeWorkloadScore(input, app, market) {
    const w = resolveWorkloadInputs(input);

    // Soft-capped components tuned for local scale
    const userScore = Math.min(28, w.activeUsers / 8); // ~224 active → 28
    const txnScore = Math.min(28, w.dailyTxnRows / 400); // ~11k rows/day → 28
    const tableScore = Math.min(12, w.tables / 40); // ~480 tables → 12
    const sizeScore = Math.min(22, w.planningDbGb / 25); // ~550 GB → 22

    const weightAvg =
      (app.cpuWeight + app.ramWeight + app.storageWeight + app.iopsWeight) / 4;
    const raw = (userScore + txnScore + tableScore + sizeScore) * weightAvg * (market.scoreScale || 1);

    return {
      score: Math.min(100, Math.round(raw)),
      concurrent: w.activeUsers,
      activeUsers: w.activeUsers,
      dailyTxnRows: w.dailyTxnRows,
      dailyInsertRows: w.dailyTxnRows,
      dailyInsertGb: w.dailyInsertGb,
      weeklyGb: w.weeklyGb,
      monthlyGb: w.monthlyGb,
      tables: w.tables,
      currentDbGb: w.currentDbGb,
      estimatedDbGb: w.estimatedDbGb,
      planningDbGb: w.planningDbGb,
      components: { userScore, txnScore, tableScore, sizeScore },
    };
  }

  function pickTier(score, marketId) {
    // Local market: never recommend "growth" — cap at upper local.
    if (marketId === 'local') {
      if (score < 18) return 'starter';
      if (score < 42) return 'standard';
      return 'upper';
    }
    if (marketId === 'regional') {
      if (score < 16) return 'starter';
      if (score < 36) return 'standard';
      if (score < 62) return 'upper';
      return 'growth';
    }
    // enterprise
    if (score < 14) return 'starter';
    if (score < 30) return 'standard';
    if (score < 50) return 'upper';
    return 'growth';
  }

  function recommendHadr(app, input, tier, market) {
    const criticality = input.criticality || 'medium';
    const rpoMinutes = Number(input.rpoMinutes);
    const bias = app.hadrBias;

    let level = 'None / backups only';
    let detail = 'Nightly full + frequent log/WAL backups may be enough for local mid-market.';

    const forceHigh =
      criticality === 'mission' ||
      criticality === 'high' ||
      bias === 'high' ||
      (market.id !== 'local' && tier === 'growth') ||
      (!Number.isNaN(rpoMinutes) && rpoMinutes <= 15);

    const forceMedium = bias === 'medium' || criticality === 'medium' || tier === 'upper';

    if (forceHigh) {
      level = 'High (sync/near-sync HADR)';
      detail =
        'SQL Server: Always On AG (sync + async DR). PostgreSQL: primary + sync standby + async DR, or managed HA.';
    } else if (forceMedium || bias !== 'low') {
      level = 'Medium (async replica + backups)';
      detail =
        market.id === 'local'
          ? 'For most local deployments: strong backups + optional async replica. Sync AG only if RPO is near zero.'
          : 'Async readable replica for failover/reporting, plus PITR backups. RPO typically minutes.';
    } else if (criticality === 'low' && bias === 'low') {
      level = 'Low (backups + restartable jobs)';
      detail = 'Reliable backups and tested restore runbooks; replica optional.';
    }

    return { level, detail };
  }

  function recommendNetwork(tier, app, concurrent, market) {
    const base = TIER_SPECS[tier].networkMbps;
    const scaled = Math.round(
      base * app.networkWeight * (1 + Math.min(0.5, concurrent / 400))
    );
    let label = market.networkClass || '1 GbE class';
    if (scaled >= 5000) label = '10 GbE class';
    else if (scaled >= 2000) label = '1–2 GbE class';
    else label = '1 GbE class';
    return { mbps: scaled, label };
  }

  function recommendStorage(tier, app, workload, market) {
    const base = TIER_SPECS[tier].storageGb;
    // Start from planning DB size (current vs estimated) + 12 months growth + indexes/temp + headroom
    const fromDbSize = Math.ceil(workload.planningDbGb * 1.6 * 1.5); // indexes/temp × headroom
    const fromGrowth = Math.ceil(workload.monthlyGb * 12 * 1.6 * 1.4);
    let storageGb = Math.max(base, fromDbSize, fromGrowth);

    // Snap to common local SSD sizes
    const steps =
      market.id === 'local'
        ? [256, 512, 768, 1024]
        : market.id === 'regional'
          ? [256, 512, 768, 1024, 1536, 2048]
          : [256, 512, 1024, 2048, 4096, 8192, 10240];

    storageGb = steps.find((n) => n >= storageGb) || Math.min(storageGb, market.maxStorageGb);
    storageGb = Math.min(storageGb, market.maxStorageGb);

    const profile = STORAGE_PROFILES[app.storageProfile] || STORAGE_PROFILES.ssd_standard;
    return {
      storageGb,
      profile,
      projectedDataGb: Math.ceil(
        Math.max(workload.planningDbGb, workload.monthlyGb * 12)
      ),
    };
  }

  function recommendCpuRam(tier, app, score, concurrent, market) {
    const base = TIER_SPECS[tier];
    // Keep starter / very light loads on the tier baseline; apply app weights as load grows.
    let vcpu = base.vcpu;
    let ramGb = base.ramGb;
    if (score >= 18) {
      vcpu = Math.ceil(base.vcpu * Math.min(1.25, app.cpuWeight));
      ramGb = Math.ceil(base.ramGb * Math.min(1.35, app.ramWeight));
    } else if (score >= 10) {
      vcpu = Math.ceil(base.vcpu * Math.min(1.1, app.cpuWeight));
      ramGb = Math.ceil(base.ramGb * Math.min(1.15, app.ramWeight));
    }

    // Local-scale concurrency bumps (much softer than old enterprise model)
    if (concurrent >= 100) {
      vcpu = Math.max(vcpu, 12);
      ramGb = Math.max(ramGb, 48);
    }
    if (concurrent >= 200 || score >= 70) {
      vcpu = Math.max(vcpu, market.id === 'local' ? 16 : 24);
      ramGb = Math.max(ramGb, market.id === 'local' ? 64 : 96);
    }

    // Snap to common local / cloud sizes (include 10/12/48 for mid-market boxes)
    const vcpuSteps =
      market.id === 'local'
        ? [4, 8, 10, 12, 16]
        : market.id === 'regional'
          ? [4, 8, 12, 16, 20, 24]
          : [4, 8, 16, 24, 32, 48, 64];
    const ramSteps =
      market.id === 'local'
        ? [16, 32, 48, 64]
        : market.id === 'regional'
          ? [16, 32, 48, 64, 96]
          : [16, 32, 64, 128, 256, 384, 512];

    vcpu = vcpuSteps.find((n) => n >= vcpu) || vcpuSteps[vcpuSteps.length - 1];
    ramGb = ramSteps.find((n) => n >= ramGb) || ramSteps[ramSteps.length - 1];

    vcpu = Math.min(vcpu, market.maxVcpu);
    ramGb = Math.min(ramGb, market.maxRamGb);

    return { vcpu, ramGb };
  }

  function sizeServer(input) {
    const market = MARKET_PROFILES[input.marketProfile] || MARKET_PROFILES.local;
    const app = APP_TYPES[input.appType] || APP_TYPES.oltp;
    const workload = computeWorkloadScore(input, app, market);
    const tier = pickTier(workload.score, market.id);
    const { vcpu, ramGb } = recommendCpuRam(
      tier,
      app,
      workload.score,
      workload.activeUsers,
      market
    );
    const storage = recommendStorage(tier, app, workload, market);
    const network = recommendNetwork(tier, app, workload.activeUsers, market);
    const hadr = recommendHadr(app, input, tier, market);
    const tierSpec = TIER_SPECS[tier];
    const engine = input.dbEngine || 'both';

    const cappedNotes = [];
    if (market.id === 'local') {
      cappedNotes.push(
        `Local market caps applied: ≤${market.maxVcpu} cores, ≤${market.maxRamGb} GB RAM, ≤${market.maxStorageGb} GB SSD.`
      );
      if (workload.dailyTxnRows <= 10000) {
        cappedNotes.push(
          'Daily transactions ≤10k rows — fits common local mid-market boxes (32–64 GB / 8–16 cores / 512 GB–1 TB).'
        );
      }
    }

    return {
      app,
      market,
      workload,
      tier,
      tierLabel: tierSpec.label,
      tierDescription: tierSpec.description,
      recommendation: {
        serverType: tierSpec.label,
        vcpu,
        ramGb,
        storageGb: storage.storageGb,
        storageType: storage.profile.label,
        storageIopsHint: storage.profile.iopsHint,
        networkMbps: network.mbps,
        networkLabel: network.label,
        hadrLevel: hadr.level,
        hadrDetail: hadr.detail,
        dbEngine: engine,
        projectedAnnualDataGb: storage.projectedDataGb,
        marketProfile: market.label,
        currentDbGb: workload.currentDbGb,
        estimatedDbGb: workload.estimatedDbGb,
      },
      rationale: [
        `Market: ${market.label}. Workload score ${workload.score}/100 → ${tierSpec.label} tier.`,
        `~${workload.activeUsers} active users; ~${workload.dailyTxnRows.toLocaleString()} txn rows/day; ~${workload.tables} tables.`,
        `DB size planning: current ~${workload.currentDbGb} GB vs estimated start ~${workload.estimatedDbGb} GB (plan on ~${workload.planningDbGb} GB).`,
        `App type “${app.label}” applies CPU×${app.cpuWeight}, RAM×${app.ramWeight}, storage×${app.storageWeight}.`,
        ...cappedNotes,
        ...market.notes,
        ...app.notes,
      ],
      formulas: {
        marketCaps: `${market.label}: max ${market.maxVcpu} vCPU / ${market.maxRamGb} GB RAM / ${market.maxStorageGb} GB storage`,
        activeUsers: 'from Active users dropdown (or legacy concurrent ≈ users × 10%)',
        transactions: 'from Transactions/day dropdown midpoint (local typical &lt;10k)',
        dbSize: 'planning size = max(current DB, estimated DB to start)',
        storage:
          'storage ≈ max(tier base, planning DB×1.6×1.5, monthly×12×1.6×1.4), snapped to SSD sizes & market cap',
        score:
          'score from active users + daily txn rows + tables + DB size, weighted by app type × market scale',
      },
      inputSummary: {
        market: market.label,
        transactionsPerDay: optionLabel('transactionsPerDay', input.transactionsPerDay),
        activeUsers: optionLabel('activeUsers', input.activeUsersRange) || `${workload.activeUsers}`,
        tables: optionLabel('tables', input.tablesRange) || `${workload.tables}`,
        currentDbSize: optionLabel('dbSizeGb', input.currentDbSizeRange) || `${workload.currentDbGb} GB`,
        estimatedDbSize:
          optionLabel('dbSizeGb', input.estimatedDbSizeRange) || `${workload.estimatedDbGb} GB`,
      },
    };
  }

  return {
    MARKET_PROFILES,
    INPUT_OPTIONS,
    APP_TYPES,
    TIER_SPECS,
    STORAGE_PROFILES,
    sizeServer,
    computeWorkloadScore,
    pickTier,
    resolveWorkloadInputs,
  };
})();
