/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    name AS ConfigName,
    value AS ConfigValue,
    value_for_secondary AS ValueForSecondary,
    is_value_default AS IsValueDefault
FROM sys.database_scoped_configurations
ORDER BY name;
