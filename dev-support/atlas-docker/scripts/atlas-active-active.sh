#!/bin/bash
# =============================================================================
# Atlas Active-Active startup script
#
# Called by every Atlas container regardless of RUN_MODE.  The RUN_MODE
# environment variable drives which subsystems start:
#
#   INITIALIZER          One-shot: graph schema + type-defs + patches → exit 0
#   METADATA_SERVER      REST + search + entity CRUD (long-lived)
#   NOTIFICATION_PROCESSOR  Hook Kafka consumer (long-lived)
#   MONOLITHIC (default) Everything on one node (backward-compatible)
#
# The JVM receives RUN_MODE via -DRUN_MODE so AtlasRunMode.resolve() picks it
# up at class-load time (before Spring context is built).
#
# NOTE: no 'set -euo pipefail' — process management scripts use grep/ps/kill
#       commands that legitimately return non-zero (no match), and pipefail
#       would cause spurious exits.
# =============================================================================

RUN_MODE="${RUN_MODE:-MONOLITHIC}"
ATLAS_HOME="${ATLAS_HOME:-/opt/atlas}"
# Sentinel lives in /opt/atlas/data (the named volume mount point) so it
# persists across container restarts without shadowing the full installation.
SENTINEL="${ATLAS_HOME}/data/.setupDone"

echo "============================================================"
echo " Atlas Active-Active startup"
echo " RUN_MODE          = ${RUN_MODE}"
echo " ATLAS_HOME        = ${ATLAS_HOME}"
echo " ATLAS_BACKEND     = ${ATLAS_BACKEND:-hbase}"
echo " ATLAS_VERSION     = ${ATLAS_VERSION:-unknown}"
echo "============================================================"

# ---------------------------------------------------------------------------
# One-time per-container configuration
# ---------------------------------------------------------------------------
if [ ! -f "${SENTINEL}" ]; then
    echo "[setup] First start — configuring atlas-application.properties…"

    encryptedPwd=$(${ATLAS_HOME}/bin/cputil.py -g -u admin -p atlasR0cks! -s | tail -1)
    echo "admin=ADMIN::${encryptedPwd}" > "${ATLAS_HOME}/conf/users-credentials.properties"

    PROPS="${ATLAS_HOME}/conf/atlas-application.properties"

    sed -i "s|atlas.graph.storage.hostname=.*|atlas.graph.storage.hostname=atlas-zk.example.com:2181|" "${PROPS}"
    sed -i "s|atlas.audit.hbase.zookeeper.quorum=.*|atlas.audit.hbase.zookeeper.quorum=atlas-zk.example.com:2181|" "${PROPS}"
    sed -i "s|^atlas.graph.index.search.solr.mode=cloud|# atlas.graph.index.search.solr.mode=cloud|" "${PROPS}"
    sed -i "s|^# *atlas.graph.index.search.solr.mode=http|atlas.graph.index.search.solr.mode=http|" "${PROPS}"
    sed -i "s|^.*atlas.graph.index.search.solr.http-urls=.*|atlas.graph.index.search.solr.http-urls=http://atlas-solr.example.com:8983/solr|" "${PROPS}"
    sed -i "s|atlas.notification.embedded=.*|atlas.notification.embedded=false|" "${PROPS}"
    sed -i "s|atlas.kafka.bootstrap.servers=.*|atlas.kafka.bootstrap.servers=atlas-kafka.example.com:9092|" "${PROPS}"
    sed -i "/^atlas.kafka.zookeeper.connect=/d" "${PROPS}"


    # Header-based authentication — stateless, no session affinity needed.
    # The client passes x-awc-username/x-awc-roles/x-awc-requestid headers
    # and Atlas trusts them directly without maintaining server-side sessions.
    # This allows pure round-robin load balancing across all metadata-server
    # replicas without ip_hash.
    if [ "${RUN_MODE}" = "METADATA_SERVER" ] || [ "${RUN_MODE}" = "MONOLITHIC" ]; then
        if grep -q "^atlas.authn.header.enabled=" "${PROPS}"; then
            sed -i "s|^atlas.authn.header.enabled=.*|atlas.authn.header.enabled=true|" "${PROPS}"
        else
            echo "atlas.authn.header.enabled=true" >> "${PROPS}"
        fi
        if grep -q "^atlas.authn.header.username=" "${PROPS}"; then
            sed -i "s|^atlas.authn.header.username=.*|atlas.authn.header.username=x-awc-username|" "${PROPS}"
        else
            echo "atlas.authn.header.username=x-awc-username" >> "${PROPS}"
        fi
        if grep -q "^atlas.authn.header.roles=" "${PROPS}"; then
            sed -i "s|^atlas.authn.header.roles=.*|atlas.authn.header.roles=x-awc-roles|" "${PROPS}"
        else
            echo "atlas.authn.header.roles=x-awc-roles" >> "${PROPS}"
        fi
        if grep -q "^atlas.authn.header.requestid=" "${PROPS}"; then
            sed -i "s|^atlas.authn.header.requestid=.*|atlas.authn.header.requestid=x-awc-requestid|" "${PROPS}"
        else
            echo "atlas.authn.header.requestid=x-awc-requestid" >> "${PROPS}"
        fi
    fi

    if grep -q "^atlas.graph.storage.hbase.compression-algorithm=" "${PROPS}"; then
        sed -i "s|^atlas.graph.storage.hbase.compression-algorithm=.*|atlas.graph.storage.hbase.compression-algorithm=NONE|" "${PROPS}"
    else
        echo "atlas.graph.storage.hbase.compression-algorithm=NONE" >> "${PROPS}"
    fi
    if grep -q "^atlas.graph.graph.replace-instance-if-exists=" "${PROPS}"; then
        sed -i "s|^atlas.graph.graph.replace-instance-if-exists=.*|atlas.graph.graph.replace-instance-if-exists=true|" "${PROPS}"
    else
        echo "atlas.graph.graph.replace-instance-if-exists=true" >> "${PROPS}"
    fi

    if [ "${ATLAS_BACKEND:-hbase}" = "postgres" ]; then
        sed -i "s|^atlas.graph.storage.backend=hbase2|# atlas.graph.storage.backend=hbase2|" "${PROPS}"
        sed -i "s|atlas.EntityAuditRepository.impl=.*|# atlas.EntityAuditRepository.impl=org.apache.atlas.repository.audit.HBaseBasedAuditRepository|" "${PROPS}"
        cat >> "${PROPS}" <<EOF

atlas.graph.storage.backend=rdbms
atlas.graph.storage.rdbms.jpa.hikari.driverClassName=org.postgresql.Driver
atlas.graph.storage.rdbms.jpa.hikari.jdbcUrl=jdbc:postgresql://atlas-db/atlas
atlas.graph.storage.rdbms.jpa.hikari.username=atlas
atlas.graph.storage.rdbms.jpa.hikari.password=atlasR0cks!
atlas.graph.storage.rdbms.jpa.hikari.maximumPoolSize=40
atlas.EntityAuditRepository.impl=org.apache.atlas.repository.audit.rdbms.RdbmsBasedAuditRepository
EOF
    fi

    chown -R atlas:atlas "${ATLAS_HOME}/"
    touch "${SENTINEL}"
    echo "[setup] Done — sentinel written to ${SENTINEL}"
else
    echo "[setup] Already configured (sentinel exists), skipping."
fi

# ---------------------------------------------------------------------------
# INITIALIZER: if initialization already completed in a prior run of this
# container, exit 0 immediately (Docker Compose may restart the container).
# ---------------------------------------------------------------------------
if [ "${RUN_MODE}" = "INITIALIZER" ]; then
    if grep -rl "initialization complete, exiting" "${ATLAS_HOME}/logs/" > /dev/null 2>&1; then
        echo "[initializer] Already completed in a prior run — exiting 0 immediately."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Pass RUN_MODE to the JVM
# ---------------------------------------------------------------------------
export ATLAS_OPTS="${ATLAS_OPTS:-} -DRUN_MODE=${RUN_MODE}"

echo "[start] Launching Atlas (RUN_MODE=${RUN_MODE})…"

if [ "${RUN_MODE}" = "INITIALIZER" ]; then
    # -------------------------------------------------------------------------
    # INITIALIZER: atlas_start.py blocks until the HTTP server responds, but in
    # INITIALIZER mode Atlas calls System.exit(0) after init — the JVM exits,
    # atlas_start.py times out, and returns AFTER the JVM is already gone.
    # Running atlas_start.py in the background lets us poll the log sentinel
    # directly without depending on atlas_start.py's return code or timing.
    # -------------------------------------------------------------------------
    su -c "cd ${ATLAS_HOME}/bin && ./atlas_start.py" atlas &
    ATLAS_START_PID=$!
    echo "[initializer] Atlas starting (bg PID=${ATLAS_START_PID})…"

    MAX_WAIT=900   # 15 minutes
    ELAPSED=0
    while [ ${ELAPSED} -lt ${MAX_WAIT} ]; do
        # Success: initialization complete sentinel in logs
        if grep -rl "initialization complete, exiting" "${ATLAS_HOME}/logs/" > /dev/null 2>&1; then
            echo "[initializer] Initialization complete — store is ready for peer nodes."
            exit 0
        fi
        # atlas_start.py exited — do a final check before giving up
        if ! kill -0 "${ATLAS_START_PID}" 2>/dev/null; then
            if grep -rl "initialization complete, exiting" "${ATLAS_HOME}/logs/" > /dev/null 2>&1; then
                echo "[initializer] Initialization complete — store is ready for peer nodes."
                exit 0
            else
                echo "[initializer][ERROR] atlas_start.py exited before initialization completed." >&2
                exit 1
            fi
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        echo "[initializer] Initializing… (${ELAPSED}s / ${MAX_WAIT}s)"
    done
    echo "[initializer][ERROR] Initialization timed out after ${MAX_WAIT}s." >&2
    exit 1

else
    # -------------------------------------------------------------------------
    # Long-lived modes (METADATA_SERVER, NOTIFICATION_PROCESSOR, MONOLITHIC):
    # atlas_start.py returns after verifying HTTP is ready. Then we find the
    # JVM PID and keep the container alive.
    # -------------------------------------------------------------------------
    su -c "cd ${ATLAS_HOME}/bin && ./atlas_start.py" atlas

    ATLAS_PID=""
    i=0
    while [ $i -lt 12 ]; do
        if [ -f "${ATLAS_HOME}/logs/atlas.pid" ]; then
            _pid=$(cat "${ATLAS_HOME}/logs/atlas.pid" 2>/dev/null | tr -d '[:space:]')
            if [ -n "${_pid}" ] && kill -0 "${_pid}" 2>/dev/null; then
                ATLAS_PID="${_pid}"
                break
            fi
        fi
        _pid=$(ps -ef | grep -v grep | grep -i "org.apache.atlas.Atlas" | awk '{print $2}' | head -1)
        if [ -n "${_pid}" ]; then
            ATLAS_PID="${_pid}"
            break
        fi
        i=$((i + 1))
        sleep 5
    done

    if [ -z "${ATLAS_PID}" ]; then
        echo "[error] Atlas JVM did not start — check ${ATLAS_HOME}/logs/" >&2
        exit 1
    fi

    echo "[${RUN_MODE}] Atlas JVM started (PID=${ATLAS_PID})"
    tail --pid="${ATLAS_PID}" -f /dev/null
fi
