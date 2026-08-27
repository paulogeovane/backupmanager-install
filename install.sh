#!/usr/bin/env bash
#
# Instalador do BackupManager. Baixa o binário, instala os clientes de banco,
# cria o serviço — termina com o painel no ar.
#
#   sudo ./install.sh
#
# Numa máquina limpa, sem código nem credencial:
#
#   curl -fsSL https://raw.githubusercontent.com/paulogeovane/backupmanager-install/main/install.sh | sudo bash
#
# Repetir a execução atualiza o binário sem tocar em dados nem na configuração.
#
# Opções por variável de ambiente:
#   BM_ADDR=127.0.0.1:8090       onde o painel escuta (padrão: todas as interfaces)
#   BM_TLS_HOSTS=backup.seu.com  nomes que entram no certificado
#   BM_TLS_CERT / BM_TLS_KEY     usa um certificado seu em vez do autoassinado
#   BM_VERSAO=v0.2.0             instala uma versão específica em vez da última
#
set -euo pipefail

# O binário mora em /opt, num diretório do usuário do serviço: é o que permite
# ao painel se atualizar sozinho sem rodar como root. O link em /usr/local/bin
# é só para o comando existir no PATH.
BIN_DIR=/opt/backupmanager
BIN=$BIN_DIR/backupmanager
LINK=/usr/local/bin/backupmanager
CONF_DIR=/etc/backupmanager
CONF="$CONF_DIR/bm.env"
DATA_DIR=/var/lib/backupmanager
SERVICE_USER=backupmanager
REPO_DIST=paulogeovane/backupmanager-install

msg()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "rode com sudo."
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }

# ─── Clientes de banco ────────────────────────────────────────────────────
# O dump é feito pelo cliente oficial de cada banco: mysqldump e pg_dump são
# os únicos programas que produzem um arquivo que o próprio banco garante
# restaurar. Sem eles o serviço sobe, mas todo backup falha.
msg "Clientes de banco"
FALTAM=()
command -v mysqldump >/dev/null 2>&1 || FALTAM+=(mariadb-client)
command -v pg_dump   >/dev/null 2>&1 || FALTAM+=(postgresql-client)
if [ ${#FALTAM[@]} -gt 0 ]; then
    apt-get update -qq
    apt-get install -y -qq "${FALTAM[@]}" >/dev/null || warn "não consegui instalar: ${FALTAM[*]}"
fi
command -v mysqldump >/dev/null 2>&1 && ok "mysqldump ($(mysqldump --version | head -1 | awk '{print $3}'))" || warn "mysqldump ausente: backups MySQL vão falhar"
command -v pg_dump   >/dev/null 2>&1 && ok "pg_dump ($(pg_dump --version | awk '{print $3}'))"   || warn "pg_dump ausente: backups PostgreSQL vão falhar"

# ─── Binário ──────────────────────────────────────────────────────────────
# Estático, do repositório público de distribuição. O checksum é conferido
# ANTES de trocar: um download truncado vira um serviço que não sobe.
msg "Binário"
case "$(uname -m)" in
    x86_64)  ARQ=amd64 ;;
    aarch64) ARQ=arm64 ;;
    *) die "arquitetura não suportada: $(uname -m)" ;;
esac

if [ -n "${BM_VERSAO:-}" ]; then
    BASE="https://github.com/$REPO_DIST/releases/download/$BM_VERSAO"
else
    BASE="https://github.com/$REPO_DIST/releases/latest/download"
fi

mkdir -p "$BIN_DIR"
curl -fsSL -o "$BIN.novo" "$BASE/backupmanager-linux-$ARQ" || die "não consegui baixar o binário de $BASE"
curl -fsSL -o /tmp/SHA256SUMS "$BASE/SHA256SUMS" || die "não consegui baixar o SHA256SUMS"

ESPERADO=$(awk -v a="backupmanager-linux-$ARQ" '$2 == a {print $1}' /tmp/SHA256SUMS)
OBTIDO=$(sha256sum "$BIN.novo" | awk '{print $1}')
[ -n "$ESPERADO" ] || die "o SHA256SUMS publicado não traz backupmanager-linux-$ARQ"
[ "$ESPERADO" = "$OBTIDO" ] || { rm -f "$BIN.novo"; die "o binário baixado não confere com o checksum publicado."; }
ok "checksum conferido"

chmod 755 "$BIN.novo"
# Só troca no fim: uma falha antes daqui não pode deixar o serviço sem binário.
mv "$BIN.novo" "$BIN"
# Instalação antiga tinha o binário direto em /usr/local/bin; vira link.
[ -L "$LINK" ] || rm -f "$LINK"
ln -sfn "$BIN" "$LINK"
ok "$BIN ($("$BIN" --versao | awk '{print $2}'), $(du -h "$BIN" | cut -f1))"

# ─── Usuário e diretórios ─────────────────────────────────────────────────
msg "Usuário e diretórios"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    ok "usuário $SERVICE_USER criado"
else
    ok "usuário $SERVICE_USER já existe"
fi
mkdir -p "$DATA_DIR" "$CONF_DIR"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$DATA_DIR" "$BIN_DIR"
chmod 750 "$DATA_DIR"
ok "$DATA_DIR e $BIN_DIR"

# ─── Configuração ─────────────────────────────────────────────────────────
msg "Configuração"
IP_PUBLICO=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

if [ -f "$CONF" ]; then
    ok "$CONF já existe; mantido"

    # Instalação anterior escutava só no loopback, quando o painel ainda não
    # servia HTTPS. Agora serve, então migra para ficar acessível de fora —
    # que é o motivo de ele existir. Só o valor que ERA o padrão é trocado;
    # um endereço escolhido à mão é decisão de alguém e fica como está.
    if grep -q '^BM_ADDR=127.0.0.1:8090$' "$CONF"; then
        sed -i 's|^BM_ADDR=127.0.0.1:8090$|BM_ADDR=0.0.0.0:8090|' "$CONF"
        warn "o painel passou a escutar em todas as interfaces (antes: só localhost)"
    fi
    if ! grep -q '^BM_TLS_HOSTS=' "$CONF"; then
        echo "BM_TLS_HOSTS=${BM_TLS_HOSTS:-$IP_PUBLICO}" >> "$CONF"
    fi
else
    cat > "$CONF" <<EOF
# Cifra as senhas guardadas no banco (do MySQL/PostgreSQL de origem e do FTP/SFTP).
# ATENÇÃO: trocar esta chave torna ilegível tudo que já foi cifrado.
BM_ENCRYPTION_KEY=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')

# O painel serve o próprio HTTPS, sem depender de proxy nenhum na frente.
BM_ADDR=${BM_ADDR:-0.0.0.0:8090}

# Nomes que entram no certificado. Sem um certificado seu em BM_TLS_CERT, o
# painel gera um autoassinado no primeiro arranque: o navegador avisa uma vez
# que não conhece quem emitiu, e o tráfego é cifrado do mesmo jeito. Pedir
# certificado ao Let's Encrypt exigiria as portas 80 ou 443 livres.
BM_TLS_HOSTS=${BM_TLS_HOSTS:-$IP_PUBLICO}

BM_DATA_DIR=${DATA_DIR}
TZ=America/Sao_Paulo
EOF
    chmod 600 "$CONF"
    chown root:"$SERVICE_USER" "$CONF"
    chmod 640 "$CONF"
    ok "$CONF criado"
fi

# ─── Serviço ──────────────────────────────────────────────────────────────
msg "Serviço"
cat > /etc/systemd/system/backupmanager.service <<'UNIT'
[Unit]
Description=BackupManager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/backupmanager/backupmanager
EnvironmentFile=/etc/backupmanager/bm.env

# Restart=always é também o mecanismo de atualização: o painel troca o
# binário e encerra; o systemd o traz de volta já na versão nova. Assim não
# precisa de privilégio para chamar systemctl.
Restart=always
RestartSec=2s

User=backupmanager
Group=backupmanager

# Encerramento gracioso: o SIGTERM inicia o shutdown, e o tempo generoso
# evita cortar um dump pela metade.
KillSignal=SIGTERM
TimeoutStopSec=300

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/backupmanager /opt/backupmanager
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable backupmanager >/dev/null 2>&1
systemctl restart backupmanager
sleep 2

if systemctl is-active --quiet backupmanager; then
    ok "no ar"
else
    journalctl -u backupmanager -n 20 --no-pager
    die "o serviço não subiu (log acima)."
fi

# ─── Fim ──────────────────────────────────────────────────────────────────
ADDR=$(grep -E '^BM_ADDR=' "$CONF" | cut -d= -f2-)
PORTA=${ADDR##*:}
HOSTS=$(grep -E '^BM_TLS_HOSTS=' "$CONF" | cut -d= -f2- | cut -d, -f1)
[ -n "$HOSTS" ] || HOSTS=$IP_PUBLICO

cat <<FIM

────────────────────────────────────────────────────────────
 Instalado.

   Painel      https://${HOSTS}:${PORTA}
   Log         journalctl -u backupmanager -f
   Reiniciar   systemctl restart backupmanager
   Config      ${CONF}

 O primeiro acesso cria o usuário administrador.

 O certificado é autoassinado: o navegador vai avisar uma vez que não
 conhece quem o emitiu. Pode prosseguir — o tráfego é cifrado do mesmo
 jeito, e é o que impede sua senha de trafegar legível. Para um
 certificado sem aviso, aponte BM_TLS_CERT e BM_TLS_KEY em ${CONF}.

 Se a porta ${PORTA} estiver fechada no firewall do provedor, libere-a —
 ou acesse por túnel:

   ssh -L ${PORTA}:127.0.0.1:${PORTA} root@${HOSTS}
   e abra https://localhost:${PORTA}
────────────────────────────────────────────────────────────

FIM
