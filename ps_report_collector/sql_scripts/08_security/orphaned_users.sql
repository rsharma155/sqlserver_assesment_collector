/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    dp.name AS UserName,
    dp.type_desc AS UserType,
    dp.create_date AS CreateDate,
    dp.default_schema_name AS DefaultSchema
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S', 'U', 'G')
  AND dp.principal_id > 4
  AND dp.authentication_type_desc = 'INSTANCE'
  AND sp.sid IS NULL
ORDER BY UserName;
