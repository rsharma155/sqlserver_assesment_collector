/**
 * SQL Server configuration recommendations from hardware inputs.
 * Best-practice oriented (OLTP-friendly defaults with workload overrides).
 */
window.SqlServerConfig = (() => {
  // Buffer-pool ceilings. Enterprise is limited by the OS, not by a fixed cap.
  const EDITION_CAP_MB = {
    express: 1410,
    web: 64 * 1024,
    standard: 128 * 1024,
    enterprise: null,
  };

  /**
   * Glenn Berry / Jonathan Kehayias OS reservation, as used by
   * https://dbtune.az/blog/mssql-max-server-memory.html
   * 1 GB always + 1 GB per 4 GB of RAM up through 16 GB + 1 GB per 8 GB above 16 GB.
   * 64 GB → 1 + 4 + 6 = 11 GB reserved.
   */
  function osReserveGb(ramGb) {
    const ram = Math.max(0, Number(ramGb) || 0);
    let reserve = 1;
    reserve += Math.floor(Math.min(ram, 16) / 4);
    if (ram > 16) reserve += Math.floor((ram - 16) / 8);
    return reserve;
  }

  function recommendMaxDop(vcpu, numaNodes, workload) {
    const nodes = Math.max(1, numaNodes || 1);
    const coresPerNuma = Math.max(1, Math.floor(vcpu / nodes));
    // Common guidance: keep MAXDOP <= 8 and <= cores per NUMA
    let maxDop = Math.min(8, coresPerNuma);
    if (workload === 'oltp') maxDop = Math.min(4, maxDop);
    if (workload === 'reporting' || workload === 'mixed') maxDop = Math.min(8, coresPerNuma);
    if (vcpu <= 2) maxDop = 1;
    return Math.max(1, maxDop);
  }

  function tempdbFiles(vcpu) {
    // Microsoft guidance: start with 4–8, up to logical cores, capped at 8 initially
    if (vcpu <= 4) return vcpu;
    return Math.min(8, vcpu);
  }

  function recommend(input) {
    const vcpu = Math.max(1, Number(input.vcpu) || 4);
    const ramGb = Math.max(1, Number(input.ramGb) || 16);
    const storageType = input.storageType || 'ssd';
    const cpuType = input.cpuType || 'general'; // general | compute | memory
    const numaNodes = Math.max(1, Number(input.numaNodes) || 1);
    const workload = input.workload || 'oltp';
    const storageGb = Math.max(1, Number(input.storageGb) || 250);

    const edition = String(input.sqlEdition || 'enterprise').toLowerCase();
    const instances = Math.max(1, Math.round(Number(input.sqlInstances) || 1));
    const otherServicesGb = Math.max(0, Number(input.otherServicesGb) || 0);
    const alwaysOnReadable = Boolean(input.alwaysOnReadable);

    const reserve = osReserveGb(ramGb);
    let poolGb = ramGb - reserve - otherServicesGb;
    let alwaysOnGb = 0;
    if (alwaysOnReadable && poolGb > 0) {
      // Article: leave 10–15% extra headroom for a readable replica. Use 12%.
      alwaysOnGb = poolGb * 0.12;
      poolGb -= alwaysOnGb;
    }
    const perInstanceGb = poolGb / instances;
    const editionCapMb = Object.prototype.hasOwnProperty.call(EDITION_CAP_MB, edition)
      ? EDITION_CAP_MB[edition]
      : null;
    let maxServerMemoryMb = Math.round(perInstanceGb * 1024);
    let editionCapped = false;
    if (editionCapMb != null && maxServerMemoryMb > editionCapMb) {
      maxServerMemoryMb = editionCapMb;
      editionCapped = true;
    }
    if (!Number.isFinite(maxServerMemoryMb) || maxServerMemoryMb < 256) {
      maxServerMemoryMb = Math.min(256, editionCapMb || 256);
    }

    const sharedHost = instances > 1 || otherServicesGb > 0 || alwaysOnReadable;
    const minServerMemoryMb = sharedHost ? Math.round(maxServerMemoryMb / 2) : 0;
    const maxDop = recommendMaxDop(vcpu, numaNodes, workload);
    const costThreshold = workload === 'oltp' ? 50 : workload === 'reporting' ? 25 : 40;
    const tempdb = tempdbFiles(vcpu);

    const optimizeForAdHoc = workload === 'oltp' || workload === 'mixed';
    const backupCompression = true;

    const settings = [
      {
        name: 'max server memory (MB)',
        value: maxServerMemoryMb,
        why: memoryWhy({
          ramGb,
          reserve,
          otherServicesGb,
          alwaysOnGb,
          instances,
          editionCapped,
          editionCapMb,
          maxServerMemoryMb,
        }),
      },
      {
        name: 'min server memory (MB)',
        value: minServerMemoryMb,
        why: sharedHost
          ? 'About half of max server memory, so the buffer pool is not shrunk hard when other instances or services compete.'
          : 'Leave at 0 on a dedicated instance. Set about half of max only when instances share the host or other services compete for RAM.',
      },
      {
        name: 'max degree of parallelism',
        value: maxDop,
        why: `NUMA-aware: min(8, cores/NUMA${workload === 'oltp' ? ', 4 for OLTP' : ''}). vCPU=${vcpu}, NUMA=${numaNodes}.`,
      },
      {
        name: 'cost threshold for parallelism',
        value: costThreshold,
        why: 'Default 5 is too low; raise to reduce CXPACKET noise on OLTP.',
      },
      {
        name: 'optimize for ad hoc workloads',
        value: optimizeForAdHoc ? 1 : 0,
        why: 'Reduces plan-cache bloat from one-off queries (common in apps/ORMs).',
      },
      {
        name: 'backup compression default',
        value: backupCompression ? 1 : 0,
        why: 'Smaller/faster backups on modern CPUs; standard best practice.',
      },
      {
        name: 'remote query timeout (s)',
        value: 600,
        why: 'Safer default than unlimited for linked-server / remote calls.',
      },
      {
        name: 'tempdb data files',
        value: tempdb,
        why: 'One file per logical CPU up to 8 to reduce PFS/GAM/SGAM contention.',
      },
      {
        name: 'tempdb initial size / autogrowth',
        value: `Equal-sized files; fixed MB growth (e.g. 512–1024 MB), not %`,
        why: 'Pre-size to avoid runtime growth storms.',
      },
      {
        name: 'instant file initialization',
        value: 'Enabled (Perform Volume Maintenance Tasks)',
        why: 'Fast data-file growth/restores; does not apply to log files.',
      },
    ];

    if (storageType === 'hdd') {
      settings.push({
        name: 'storage warning',
        value: 'HDD detected — migrate to SSD/NVMe for data + tempdb + log',
        why: 'Random I/O latency on HDD will dominate waits (PAGEIOLATCH).',
      });
    } else if (storageType === 'nvme' || storageType === 'ssd') {
      settings.push({
        name: 'data / log placement',
        value: 'Separate volumes when possible; both on SSD/NVMe',
        why: 'Isolates log sequential writes from data random I/O.',
      });
    }

    const instanceHints = [
      `CPU type “${cpuType}”: ${cpuType === 'memory' ? 'favor larger buffer pool / columnstore' : cpuType === 'compute' ? 'good for parallel reporting' : 'balanced general-purpose'}.`,
      `Lock pages in memory: consider for dedicated SQL boxes (service account right) when RAM ≥ 32 GB.`,
      editionCapped
        ? `${edition} edition buffer-pool cap is ${editionCapMb} MB. RAM above that cap is not used by the buffer pool.`
        : `Edition “${edition}”: no buffer-pool cap was applied${edition === 'enterprise' ? ' (Enterprise uses the OS maximum).' : '.'}`,
      `After applying, sys.dm_os_sys_memory.system_memory_state_desc should say available physical memory is high. A healthy page-life floor is about 300 seconds per 4 GB of buffer pool (~${Math.round((maxServerMemoryMb / 1024 / 4) * 300)} seconds here).`,
      `max worker threads: leave 0 (default) unless you have a measured worker shortage.`,
      `For Always On: size network for redo + backup traffic; keep sync commit replicas close.`,
      `Storage ~${storageGb} GB: plan ~20% free on data volumes; monitor autogrowth & VLFs.`,
    ];

    const tsql = buildTsql({
      maxServerMemoryMb,
      minServerMemoryMb,
      maxDop,
      costThreshold,
      optimizeForAdHoc,
      tempdb,
    });

    return {
      engine: 'SQL Server',
      summary: {
        vcpu,
        ramGb,
        osReserveGb: reserve,
        otherServicesGb,
        alwaysOnHeadroomGb: Math.round(alwaysOnGb * 10) / 10,
        sqlInstances: instances,
        sqlEdition: edition,
        maxServerMemoryMb,
        maxDop,
        tempdbFiles: tempdb,
        storageType,
        workload,
      },
      settings,
      instanceHints,
      tsql,
    };
  }

  function memoryWhy(p) {
    const bits = [
      `OS reserve ${p.reserve} GB (1 GB + 1 GB per 4 GB up through 16 GB + 1 GB per 8 GB above 16 GB)`,
    ];
    if (p.otherServicesGb > 0) bits.push(`other services ${p.otherServicesGb} GB`);
    if (p.alwaysOnGb > 0) {
      bits.push(`Always On readable headroom ${p.alwaysOnGb.toFixed(1)} GB (12% of the remaining pool; the range is 10–15%)`);
    }
    if (p.instances > 1) bits.push(`divided by ${p.instances} instances`);
    let text = `Total RAM ${p.ramGb} GB − ${bits.join('; ')} = ${p.maxServerMemoryMb} MB.`;
    if (p.editionCapped) text += ` Clamped to the edition cap of ${p.editionCapMb} MB.`;
    return text;
  }

  function buildTsql(p) {
    return `-- Recommended starter sp_configure (review before applying)
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', ${p.maxServerMemoryMb};
EXEC sp_configure 'min server memory (MB)', ${p.minServerMemoryMb};
EXEC sp_configure 'max degree of parallelism', ${p.maxDop};
EXEC sp_configure 'cost threshold for parallelism', ${p.costThreshold};
EXEC sp_configure 'optimize for ad hoc workloads', ${p.optimizeForAdHoc ? 1 : 0};
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;
-- Tempdb: use ${p.tempdb} equal-sized data files, pre-size, fixed MB growth (not %).`;
  }

  return { recommend, osReserveGb, recommendMaxDop };
})();
