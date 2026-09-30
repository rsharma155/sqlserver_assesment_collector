/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    dp.name AS PrincipalName,
    dp.type_desc AS PrincipalType,
    dp.authentication_type_desc AS AuthenticationType,
    dp.create_date AS CreateDate,
    dp.default_schema_name AS DefaultSchema,
    CASE WHEN dp.sid IS NULL THEN 1 ELSE 0 END AS IsWithoutLogin,
    CASE WHEN dp.name = 'guest' AND dp.authentication_type_desc <> 'NONE' THEN 1 ELSE 0 END AS GuestEnabledHint,
    CASE WHEN IS_ROLEMEMBER('db_owner', dp.name) = 1 THEN 1 ELSE 0 END AS IsDbOwner
FROM sys.database_principals dp
WHERE dp.type IN ('S', 'U', 'G', 'E', 'X')
  AND dp.name NOT IN ('dbo', 'INFORMATION_SCHEMA', 'sys')
ORDER BY IsDbOwner DESC, PrincipalType, PrincipalName;
