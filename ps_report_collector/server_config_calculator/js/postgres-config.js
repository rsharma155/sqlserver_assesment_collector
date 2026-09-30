/**
 * PostgreSQL configuration recommendations from hardware inputs.
 * Based on common community / cloud best-practice formulas.
 */
window.PostgresConfig = (() => {
  function clamp(n, min, max) {
    return Math.min(max, Math.max(min, n));
  }

  function formatBytes(mb) {
    if (mb >= 1024) return `${(mb / 1024).toFixed(mb >= 10240 ? 0 : 1)}GB`;
    return `${Math.round(mb)}MB`;
  }

  function recommend(input) {
    const vcpu = Math.max(1, Number(input.vcpu) || 4);
    const ramGb = Math.max(1, Number(input.ramGb) || 16);
    const ramMb = ramGb * 1024;
    const storageType = input.storageType || 'ssd';
    const cpuType = input.cpuType || 'general';
    const workload = input.workload || 'oltp';
    const storageGb = Math.max(1, Number(input.storageGb) || 250);
    const expectedConnections = Math.max(20, Number(input.maxConnections) || 0);

    // max_connections: prefer pooler; keep DB connections modest
    let maxConnections =
      expectedConnections ||
      (workload === 'oltp' ? Math.min(200, 20 + vcpu * 15) : Math.min(150, 20 + vcpu * 10));
    if (workload === 'reporting') maxConnections = Math.min(100, 20 + vcpu * 5);

    // shared_buffers ~ 25% RAM (cap ~8–16GB often good starting; allow higher on dedicated)
    let sharedBuffersMb = Math.round(ramMb * 0.25);
    if (ramGb >= 64) sharedBuffersMb = Math.min(sharedBuffersMb, 16 * 1024);
    if (ramGb >= 256) sharedBuffersMb = Math.round(ramMb * 0.2);

    // effective_cache_size ~ 50–75% RAM
    const effectiveCacheMb = Math.round(ramMb * (workload === 'reporting' ? 0.75 : 0.65));

    // work_mem: (RAM * 0.2) / max_connections — conservative; parallel workers amplify
    const workMemMb = clamp(Math.round((ramMb * 0.2) / maxConnections), 4, workload === 'reporting' ? 256 : 64);

    // maintenance_work_mem
    const maintenanceWorkMemMb = clamp(Math.round(ramMb * 0.05), 64, 2048);

    // wal_buffers: ~3% of shared_buffers, capped 16MB
    const walBuffersMb = clamp(Math.round(sharedBuffersMb * 0.03), 4, 16);

    const randomPageCost = storageType === 'hdd' ? 4.0 : storageType === 'nvme' ? 1.1 : 1.1;
    const effectiveIoConcurrency = storageType === 'hdd' ? 2 : storageType === 'nvme' ? 200 : 200;

    const checkpointCompletionTarget = 0.9;
    const walLevel = 'replica'; // needed for backups/replicas
    const maxWalSize = storageGb >= 1000 ? '8GB' : storageGb >= 250 ? '4GB' : '2GB';
    const minWalSize = storageGb >= 250 ? '1GB' : '512MB';

    const parallelWorkers = Math.max(0, vcpu - 1);
    const maxParallelWorkersPerGather = clamp(Math.floor(vcpu / 2), 0, workload === 'oltp' ? 2 : 4);
    const maxWorkerProcesses = Math.max(8, vcpu);
    const maxParallelWorkers = Math.max(parallelWorkers, maxParallelWorkersPerGather);

    const settings = [
      {
        name: 'shared_buffers',
        value: formatBytes(sharedBuffersMb),
        why: '~25% of RAM (slightly less on very large hosts). Primary buffer cache.',
      },
      {
        name: 'effective_cache_size',
        value: formatBytes(effectiveCacheMb),
        why: 'Planner hint: OS page cache + DB buffers (~65–75% RAM).',
      },
      {
        name: 'work_mem',
        value: formatBytes(workMemMb),
        why: `(RAM×0.2)/max_connections ≈ per-sort/hash memory. Raise carefully with parallelism.`,
      },
      {
        name: 'maintenance_work_mem',
        value: formatBytes(maintenanceWorkMemMb),
        why: 'VACUUM / CREATE INDEX / ALTER TABLE latency; ~5% RAM capped at 2GB.',
      },
      {
        name: 'wal_buffers',
        value: formatBytes(walBuffersMb),
        why: '~3% of shared_buffers, max 16MB (auto often fine on PG 14+).',
      },
      {
        name: 'max_connections',
        value: maxConnections,
        why: 'Prefer PgBouncer/pooler in front; high connections waste RAM.',
      },
      {
        name: 'random_page_cost',
        value: randomPageCost,
        why: storageType === 'hdd' ? 'Default-ish for HDD.' : 'Lower for SSD/NVMe so index scans are preferred.',
      },
      {
        name: 'effective_io_concurrency',
        value: effectiveIoConcurrency,
        why: 'Concurrent bitmap-heap I/O hint; raise on SSD/NVMe.',
      },
      {
        name: 'checkpoint_completion_target',
        value: checkpointCompletionTarget,
        why: 'Spread checkpoint writes to smooth I/O spikes.',
      },
      {
        name: 'max_wal_size / min_wal_size',
        value: `${maxWalSize} / ${minWalSize}`,
        why: 'Fewer checkpoints under write load; size with free disk.',
      },
      {
        name: 'wal_level',
        value: walLevel,
        why: 'replica enables PITR and physical replication.',
      },
      {
        name: 'max_worker_processes',
        value: maxWorkerProcesses,
        why: 'Ceiling for background + parallel workers; ≥ vCPU.',
      },
      {
        name: 'max_parallel_workers',
        value: maxParallelWorkers,
        why: 'Total parallel workers available system-wide.',
      },
      {
        name: 'max_parallel_workers_per_gather',
        value: maxParallelWorkersPerGather,
        why: workload === 'oltp' ? 'Keep low for OLTP latency.' : 'Allow more parallel for analytics.',
      },
    ];

    if (storageType === 'hdd') {
      settings.push({
        name: 'storage warning',
        value: 'HDD not recommended for PostgreSQL data directory',
        why: 'High random I/O latency; use SSD/NVMe for PGDATA and preferably WAL.',
      });
    }

    const conf = buildConf({
      sharedBuffersMb,
      effectiveCacheMb,
      workMemMb,
      maintenanceWorkMemMb,
      walBuffersMb,
      maxConnections,
      randomPageCost,
      effectiveIoConcurrency,
      checkpointCompletionTarget,
      maxWalSize,
      minWalSize,
      walLevel,
      maxWorkerProcesses,
      maxParallelWorkers,
      maxParallelWorkersPerGather,
    });

    const hints = [
      `CPU type “${cpuType}”: ${cpuType === 'memory' ? 'good fit for large shared_buffers / analytics' : cpuType === 'compute' ? 'favor parallel query settings' : 'balanced defaults'}.`,
      'Use a connection pooler for app tiers; keep max_connections modest.',
      'Put WAL on fast disk; enable archive_command / continuous backup for PITR.',
      `Autovacuum: leave on; tune scale_factor on hot/large tables (storage ~${storageGb} GB).`,
      'huge_pages=try on Linux when RAM is large and shared_buffers is big.',
    ];

    return {
      engine: 'PostgreSQL',
      summary: {
        vcpu,
        ramGb,
        sharedBuffers: formatBytes(sharedBuffersMb),
        effectiveCacheSize: formatBytes(effectiveCacheMb),
        workMem: formatBytes(workMemMb),
        maxConnections,
        storageType,
        workload,
      },
      settings,
      instanceHints: hints,
      conf,
    };
  }

  function buildConf(p) {
    const sb = p.sharedBuffersMb >= 1024 ? `${Math.round(p.sharedBuffersMb / 1024)}GB` : `${p.sharedBuffersMb}MB`;
    const ec = p.effectiveCacheMb >= 1024 ? `${Math.round(p.effectiveCacheMb / 1024)}GB` : `${p.effectiveCacheMb}MB`;
    const wm = p.workMemMb >= 1024 ? `${(p.workMemMb / 1024).toFixed(1)}GB` : `${p.workMemMb}MB`;
    const mm = p.maintenanceWorkMemMb >= 1024 ? `${(p.maintenanceWorkMemMb / 1024).toFixed(1)}GB` : `${p.maintenanceWorkMemMb}MB`;

    return `# Recommended postgresql.conf starter (review before applying)
# Generated by server_config_calculator

listen_addresses = '*'
max_connections = ${p.maxConnections}

shared_buffers = ${sb}
effective_cache_size = ${ec}
work_mem = ${wm}
maintenance_work_mem = ${mm}
wal_buffers = ${p.walBuffersMb}MB

random_page_cost = ${p.randomPageCost}
effective_io_concurrency = ${p.effectiveIoConcurrency}
checkpoint_completion_target = ${p.checkpointCompletionTarget}
max_wal_size = ${p.maxWalSize}
min_wal_size = ${p.minWalSize}
wal_level = ${p.walLevel}

max_worker_processes = ${p.maxWorkerProcesses}
max_parallel_workers = ${p.maxParallelWorkers}
max_parallel_workers_per_gather = ${p.maxParallelWorkersPerGather}
`;
  }

  return { recommend };
})();
