#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# == Vars
#
DB_MIGRATION_DIR='/powerdns-admin/migrations'


# Wait for us to be able to connect to MySQL before proceeding
echo "===> Waiting for $PDA_DB_HOST MySQL service"
until nc -zv \
  $PDA_DB_HOST \
  3306;
do
  echo "MySQL ($PDA_DB_HOST) is unavailable - sleeping"
  sleep 1
done


echo "===> DB management"
# Go in Workdir
cd /powerdns-admin

if [ ! -d "${DB_MIGRATION_DIR}" ]; then
  echo "---> Running DB Init"
  flask db init --directory ${DB_MIGRATION_DIR}
  flask db migrate -m "Init DB" --directory ${DB_MIGRATION_DIR}
  flask db upgrade --directory ${DB_MIGRATION_DIR}
  ./init_data.py

else
  echo "---> Running DB Migration"
  set +e
  flask db migrate -m "Upgrade BD Schema" --directory ${DB_MIGRATION_DIR}
  flask db upgrade --directory ${DB_MIGRATION_DIR}
  set -e
fi

echo "===> Update PDNS API connection info"
# initial setting if not available in the DB
mysql -h${PDA_DB_HOST} -u${PDA_DB_USER} -p${PDA_DB_PASSWORD} ${PDA_DB_NAME} -e "INSERT INTO setting (name, value) SELECT * FROM (SELECT 'pdns_api_url', 'http://${PDNS_HOST}:8081') AS tmp WHERE NOT EXISTS (SELECT name FROM setting WHERE name = 'pdns_api_url') LIMIT 1;"
mysql -h${PDA_DB_HOST} -u${PDA_DB_USER} -p${PDA_DB_PASSWORD} ${PDA_DB_NAME} -e "INSERT INTO setting (name, value) SELECT * FROM (SELECT 'pdns_api_key', '${PDNS_API_KEY}') AS tmp WHERE NOT EXISTS (SELECT name FROM setting WHERE name = 'pdns_api_key') LIMIT 1;"

# update pdns api setting if .env is changed.
mysql -h${PDA_DB_HOST} -u${PDA_DB_USER} -p${PDA_DB_PASSWORD} ${PDA_DB_NAME} -e "UPDATE setting SET value='http://${PDNS_HOST}:8081' WHERE name='pdns_api_url';"
mysql -h${PDA_DB_HOST} -u${PDA_DB_USER} -p${PDA_DB_PASSWORD} ${PDA_DB_NAME} -e "UPDATE setting SET value='${PDNS_API_KEY}' WHERE name='pdns_api_key';"

echo "===> Assets management"
echo "---> Running Yarn"
chown -R www-data:www-data /powerdns-admin/app/static
chown -R www-data:www-data /powerdns-admin/node_modules
su -s /bin/bash -c 'yarn install --pure-lockfile' www-data

echo "---> Running Flask assets"
chown -R www-data:www-data /powerdns-admin/logs
su -s /bin/bash -c 'flask assets build' www-data


echo "===> Start supervisor"
/usr/bin/supervisord -c /etc/supervisord.conf
