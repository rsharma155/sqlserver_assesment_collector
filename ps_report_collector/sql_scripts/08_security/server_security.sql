/* SQL_Initial_Assessment */
SELECT
    sp.name AS LoginName,
    sp.type_desc AS LoginType,
    sp.is_disabled AS IsDisabled,
    sp.create_date AS CreateDate,
    sp.modify_date AS ModifyDate,
    sp.default_database_name AS DefaultDatabase,
    CASE WHEN IS_SRVROLEMEMBER('sysadmin', sp.name) = 1 THEN 1 ELSE 0 END AS IsSysadmin,
    CASE WHEN IS_SRVROLEMEMBER('securityadmin', sp.name) = 1 THEN 1 ELSE 0 END AS IsSecurityAdmin,
    CASE WHEN IS_SRVROLEMEMBER('serveradmin', sp.name) = 1 THEN 1 ELSE 0 END AS IsServerAdmin,
    LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS PasswordLastSetTime,
    LOGINPROPERTY(sp.name, 'IsLocked') AS IsLocked,
    LOGINPROPERTY(sp.name, 'IsExpired') AS IsExpired,
    LOGINPROPERTY(sp.name, 'DaysUntilExpiration') AS DaysUntilExpiration,
    CASE WHEN sp.name = 'sa' THEN 1 ELSE 0 END AS IsSa
FROM sys.server_principals sp
WHERE sp.type IN ('S', 'U', 'G')
  AND sp.name NOT LIKE '##%'
ORDER BY IsSysadmin DESC, LoginType, LoginName;
