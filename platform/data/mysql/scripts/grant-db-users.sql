-- platform/data/mysql/scripts/grant-db-users.sql
-- Creates a Microsoft Entra user for one workload managed identity and grants it its boundary database.
-- Run once per entry in contract.databases.<db>.grants, AFTER `terraform apply`, signed in as the Entra
-- administrator (settings.entra_admin) with an access token as password:
--
--   TOKEN=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
--   sed -e "s/@IDENTITY_NAME@/hello-dbadapter/g" -e "s/@CLIENT_ID@/<client id>/g" -e "s/@DB@/adapter/g" \
--     platform/data/mysql/scripts/grant-db-users.sql | \
--   mysql -h <fqdn> -u '<entra admin login>' --password="$TOKEN" --enable-cleartext-plugin --ssl-mode=REQUIRED
--
-- For managed identities, `IDENTIFIED BY '<client id>'` binds the user to the identity's client ID.
-- Re-runs: CREATE AADUSER fails with ERROR 1396 when the user exists; the pipeline treats 1396 as success
-- (run the GRANT statements with `mysql --force`). Tables are created by application migrations only.
CREATE AADUSER '@IDENTITY_NAME@' IDENTIFIED BY '@CLIENT_ID@';
GRANT ALL PRIVILEGES ON `@DB@`.* TO '@IDENTITY_NAME@'@'%';
FLUSH PRIVILEGES;
