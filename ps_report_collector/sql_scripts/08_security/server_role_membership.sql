/* SQL_Initial_Assessment */
SELECT
    r.name AS RoleName,
    r.type_desc AS RoleType,
    m.name AS MemberName,
    m.type_desc AS MemberType,
    m.is_disabled AS MemberIsDisabled
FROM sys.server_role_members rm
INNER JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
INNER JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
WHERE r.type = 'R'
ORDER BY
    CASE WHEN r.name = 'sysadmin' THEN 0 ELSE 1 END,
    r.name, m.name;
