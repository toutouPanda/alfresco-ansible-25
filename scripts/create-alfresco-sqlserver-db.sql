/* ===========================================================================
   Alfresco Content Services 25.3 -- bootstrap Microsoft SQL Server

   Cible : sql-infra22pr01.rivp-groupe.net\ALFRESCO   base : SQL_PRALFRESCO

   A executer SUR LA VM SQL SERVER, AVANT playbooks/acs.yml :

     sqlcmd -S sql-infra22pr01.rivp-groupe.net\ALFRESCO -U sa -P '<sa-password>' \
            -i create-alfresco-sqlserver-db.sql

   Remplacer <REPO_DB_PASSWORD> par la valeur de `repo_db_password` lue dans
   vars/secrets.yml (genere par playbooks/secrets-init.yml). Les deux DOIVENT
   etre identiques, sinon Tomcat demarre puis echoue sur
   "Login failed for user 'alfresco'".

   Prerequis cote instance ALFRESCO :
     - authentification mode mixte (logins SQL) activee
     - protocole TCP/IP active
     - port TCP de l'instance ouvert depuis 10.75.0.114
     - service SQL Server Browser demarre + UDP 1434 ouvert
       (uniquement si acs_sqlserver_port est laisse vide cote Ansible)
   =========================================================================== */

/* --- 0. Port TCP reel de l'instance nommee -------------------------------
   A recuperer pour renseigner acs_sqlserver_port dans
   playbooks/group_vars/all.yml (evite la dependance a SQL Server Browser).   */
SELECT DISTINCT local_tcp_port
FROM   sys.dm_exec_connections
WHERE  local_tcp_port IS NOT NULL;
GO

/* --- 1. Base -- A SAUTER si le DBA l'a deja creee ------------------------
   Collation : celle par defaut du serveur (recommandation Alfresco).        */
IF DB_ID('SQL_PRALFRESCO') IS NULL
    CREATE DATABASE SQL_PRALFRESCO;
GO

/* --- 2. Isolation SNAPSHOT -- OBLIGATOIRE --------------------------------
   Correspond a db.txn.isolation=4096 dans alfresco-global.properties.       */
ALTER DATABASE SQL_PRALFRESCO SET ALLOW_SNAPSHOT_ISOLATION ON;
GO

/* --- 3. Recommande (pas exige par la doc) : reduit les blocages ---------- */
ALTER DATABASE SQL_PRALFRESCO SET READ_COMMITTED_SNAPSHOT ON;
GO

/* --- 4. Login + user ----------------------------------------------------
   db_owner est ce que documente Alfresco : le compte doit pouvoir creer et
   modifier tables, index et sequences (y compris pendant les upgrades).     */
IF SUSER_ID('alfresco') IS NULL
    CREATE LOGIN alfresco
        WITH PASSWORD = '<REPO_DB_PASSWORD>',
             DEFAULT_DATABASE = SQL_PRALFRESCO;
GO

USE SQL_PRALFRESCO;
GO

IF USER_ID('alfresco') IS NULL
    CREATE USER alfresco FOR LOGIN alfresco;
GO

ALTER ROLE db_owner ADD MEMBER alfresco;
GO

/* --- 5. Controle final --------------------------------------------------- */
SELECT name,
       snapshot_isolation_state_desc,   -- attendu : ON
       is_read_committed_snapshot_on,
       collation_name
FROM   sys.databases
WHERE  name = 'SQL_PRALFRESCO';
GO
