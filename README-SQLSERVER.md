# ACS 25.3 Enterprise — Ubuntu + SQL Server externe + Solr6

Fork du playbook officiel [Alfresco/alfresco-ansible-deployment](https://github.com/Alfresco/alfresco-ansible-deployment)
**tag `v3.9.0`** (= dernière version ciblant ACS **25.3.2** / Search Services **2.0.19**).

## Architecture cible

| VM | Adresse | Composants |
|----|---------|-----------|
| **VM1 — Ubuntu 22.04 / 24.04** | `10.75.0.114` — `web-ged-pr01` *(nom temporaire)* | Repository (Tomcat 10.1) · Share · ADW · Control Center · API Explorer · **Solr6 / Search Services 2.0.19** · ActiveMQ 5.18 · Transform Service (AIO + Router + SFS) · Nginx · OpenJDK 17 |
| **VM2 — SQL Server (déjà en place)** | `sql-infra22pr01.rivp-groupe.net\ALFRESCO`<br>base `SQL_PRALFRESCO` | **Microsoft SQL Server 2019 / 2022** |

Pas d'Elasticsearch, pas de PostgreSQL, pas de Sync Service, pas d'Audit Storage.

## Modifications apportées au playbook officiel

| Fichier | Modification |
|---------|--------------|
| `playbooks/group_vars/all.yml` | `acs_play_major_version: 26` → **`25`** (charge `vars/acs25.yml` → ACS 25.3.2) |
| `playbooks/group_vars/all.yml` | Bloc **SQL Server** : `acs_play_repo_db_url` (jdbc:sqlserver), `acs_play_repo_db_driver` = `com.microsoft.sqlserver.jdbc.SQLServerDriver`. Une URL non vide fait **sauter tout le play « Database Role »** (PostgreSQL n'est jamais installé). |
| `playbooks/group_vars/all.yml` | `acs_play_fqdn_alfresco` + `acs_play_known_urls` renseignés (obligatoire pour CORS/CSRF de Share) |
| `inventory_sqlserver.yml` | **Nouveau.** Groupes `search_enterprise`, `elasticsearch`, `database`, `syncservice`, `audit_storage` **vides** ; groupe `search` (Solr6) rempli. |
| `configuration_files/db_connector_repo/mssql-jdbc-11.2.0.jre17.jar` | **Nouveau.** Driver JDBC. Le rôle `repository` copie automatiquement ce dossier dans `<tomcat>/lib/` dès que le driver n'est pas PostgreSQL. |
| `configuration_files/alfresco-global.properties` | `db.txn.isolation=4096` (SNAPSHOT) + `db.pool.max=275` |
| `scripts/create-alfresco-sqlserver-db.sql` | **Nouveau.** Création base + login + `ALLOW_SNAPSHOT_ISOLATION` |

> Pourquoi Solr6 est bien activé : `roles/repository/templates/alfresco-global.properties.j2` écrit
> `index.subsystem.name=solr6` **si et seulement si** le groupe `search` contient au moins un hôte,
> sinon `elasticsearch` si `search_enterprise` est rempli. D'où les groupes vides.

## Prérequis

**VM SQL Server** — instance **nommée** `ALFRESCO`
- Authentification mode mixte (logins SQL) activée
- Protocole TCP/IP activé sur l'instance
- Port TCP de l'instance ouvert depuis `10.75.0.114`
- Service **SQL Server Browser** démarré + **UDP 1434** ouvert
  *(uniquement si `acs_sqlserver_port` est laissé vide — voir « Instance nommée » plus bas)*

**VM Ubuntu** — 22.04 ou 24.04, minimum **16 Go RAM / 4 vCPU / 100 Go disque**, Python ≥ 3.11, accès Internet sortant (artifacts.alfresco.com + Maven Central)

**Compte Alfresco** — identifiants Nexus Enterprise + fichier de licence `.lic`

---

# Étapes minimales d'installation

## 1. Préparer la VM Ubuntu

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-pip pipenv git unzip
```

## 2. Récupérer ce playbook sur la VM Ubuntu

```bash
cd ~ && unzip alfresco-ansible-25.3.zip && cd alfresco-ansible-25.3
```

## 3. Installer Ansible et ses dépendances

```bash
pipenv install --deploy
pipenv run ansible-galaxy install -r requirements.yml
```

## 4. Renseigner les identifiants Nexus Enterprise

```bash
export NEXUS_USERNAME="<votre-login-alfresco>"
export NEXUS_PASSWORD="<votre-mot-de-passe>"
```

## 5. Configurer la cible

`playbooks/group_vars/all.yml` est **déjà renseigné** avec vos valeurs :

```yaml
acs_play_fqdn_alfresco: "web-ged-pr01"
acs_play_known_urls:
  - "http://web-ged-pr01"
  - "http://10.75.0.114"

acs_sqlserver_host: "sql-infra22pr01.rivp-groupe.net"
acs_sqlserver_instance: "ALFRESCO"
acs_sqlserver_port: ""                    # vide => résolution via SQL Browser
acs_sqlserver_db_name: "SQL_PRALFRESCO"
acs_sqlserver_db_username: "alfresco"     # à confirmer avec le DBA
```

Deux points à trancher :
- **`acs_sqlserver_port`** — dès que le DBA donne le port TCP statique de l'instance
  `ALFRESCO`, le renseigner ici (la requête de l'étape 7 le retourne). L'URL bascule
  alors automatiquement en `host:port` et `instanceName` est retiré.
- **`acs_play_fqdn_alfresco`** — si `web-ged-pr01` ne résout pas en DNS depuis les
  postes clients, remplacer par `10.75.0.114`. Les deux URL restent acceptées par
  Share (CORS) grâce à `acs_play_known_urls`.

Déposer la licence Enterprise :

```bash
cp /chemin/vers/votre.lic configuration_files/licenses/
```

## 6. Générer les mots de passe

```bash
pipenv run ansible-playbook -i inventory_sqlserver.yml playbooks/secrets-init.yml
```

Crée `vars/secrets.yml` (mode 0600) avec 3 secrets aléatoires de 33 caractères :
`repo_db_password`, `activemq_password`, `reposearch_shared_secret` (secret partagé Repo ↔ Solr6).

```bash
cat vars/secrets.yml
```

> Pour chiffrer le fichier : ajouter `-e vault_init=encrypted_file`, puis lancer
> toutes les commandes suivantes avec `--ask-vault-pass`.

## 7. Créer la base sur la VM SQL Server

Reporter le `repo_db_password` de l'étape 6 dans `scripts/create-alfresco-sqlserver-db.sql`
(placeholder `<REPO_DB_PASSWORD>`), puis exécuter le script sur la VM SQL Server :

```bash
sqlcmd -S sql-infra22pr01.rivp-groupe.net\ALFRESCO -U sa -P '<sa-password>' -i create-alfresco-sqlserver-db.sql
```

Le script est idempotent : il crée `SQL_PRALFRESCO` **si elle n'existe pas déjà**,
active `ALLOW_SNAPSHOT_ISOLATION` (obligatoire), crée le login/user `alfresco` en
`db_owner`, et **retourne le port TCP réel de l'instance** — à reporter dans
`acs_sqlserver_port` (étape 5).

## 8. Vérifier la connectivité puis déployer

Depuis la VM Ubuntu, contrôler que SQL Server est joignable. Le check intégré du
playbook **ne teste pas** la base quand elle est externe, donc à faire à la main :

```bash
getent hosts sql-infra22pr01.rivp-groupe.net
```

```bash
nc -zv sql-infra22pr01.rivp-groupe.net <port-instance-ALFRESCO>
```

```bash
pipenv run ansible-playbook -i inventory_sqlserver.yml playbooks/prerun-network-checks.yml
```

Puis déployer :

```bash
pipenv run ansible-playbook -i inventory_sqlserver.yml playbooks/acs.yml -K
```

Durée ≈ 30–45 min. `-K` demande le mot de passe sudo (à retirer si sudo NOPASSWD).

---

## Vérification post-installation

```bash
sudo systemctl status alfresco-content alfresco-search activemq alfresco-transform-router alfresco-shared-fs alfresco-tengine-aio nginx
```

| Service | URL |
|---------|-----|
| Share | `http://<fqdn>/share` |
| Digital Workspace | `http://<fqdn>/workspace` |
| Control Center | `http://<fqdn>/control-center` |
| API Explorer | `http://<fqdn>/api-explorer` |
| Solr6 admin | `http://<ip-vm>:8983/solr` (non exposé par Nginx) |

Login initial : `admin` / `admin` — **à changer immédiatement**.

Contrôler que Solr6 est bien le moteur actif :

```bash
sudo grep -E "index.subsystem.name|^db\." /etc/opt/alfresco/content-services/classpath/alfresco-global.properties
```

Attendu : `index.subsystem.name=solr6`, `db.driver=com.microsoft.sqlserver.jdbc.SQLServerDriver`,
`db.url=jdbc:sqlserver://...`, `db.txn.isolation=4096`.

## Logs utiles

```bash
sudo journalctl -u alfresco-content -f
sudo tail -f /var/log/alfresco/catalina.out   # repository + Share
sudo tail -f /var/log/alfresco/solr.log       # Solr6
```

Emplacements installés :

| Quoi | Chemin |
|------|--------|
| `alfresco-global.properties` | `/etc/opt/alfresco/content-services/classpath/` |
| Driver JDBC SQL Server | `/etc/opt/alfresco/tomcat/lib/mssql-jdbc-11.2.0.jre17.jar` |
| Binaires | `/opt/alfresco` · OpenJDK 17 sous `/opt/openjdk-17.0.18` |
| Données (contentstore, index Solr) | `/var/opt/alfresco` |
| Logs | `/var/log/alfresco` |

## Pièges connus

- **`encrypt`** : mssql-jdbc ≥ 10 active TLS par défaut. `acs_sqlserver_url_params` force `encrypt=false`.
  Pour du TLS, passer à `encrypt=true;trustServerCertificate=true` (ou importer le certificat du serveur
  dans le truststore de l'OpenJDK 17 installé sous `/opt/openjdk-17.0.18`).
- **Mot de passe désynchronisé** : `repo_db_password` de `vars/secrets.yml` et le login SQL Server
  doivent être identiques, sinon Tomcat démarre puis échoue sur `Login failed for user 'alfresco'`.
- **Instance nommée** : d'après la [doc Microsoft](https://learn.microsoft.com/en-us/sql/connect/jdbc/building-the-connection-url),
  si `portNumber` **et** `instanceName` figurent dans l'URL, **le port l'emporte et
  `instanceName` est ignoré silencieusement**. `acs_sqlserver_target` n'émet donc
  jamais les deux : port statique s'il est renseigné, sinon `instanceName`.
  Tant que `acs_sqlserver_port` est vide, la résolution passe par **SQL Server
  Browser en UDP 1434** — si ce port est filtré, la connexion échoue avec
  `The TCP/IP connection to the host ... has failed`.
- **Aucun hôte dans `database`** : c'est voulu. Ajouter un hôte réinstallerait PostgreSQL en local.
- **Résolution de `web-ged-pr01`** : vérifier que la VM se résout elle-même
  (`getent hosts web-ged-pr01`). Sinon ajouter `10.75.0.114 web-ged-pr01` dans
  `/etc/hosts` — `acs_play_fqdn_alfresco` sert à construire les liens générés
  par le repository (`alfresco.host`, `share.host`, `aos.baseUrlOverwrite`).
