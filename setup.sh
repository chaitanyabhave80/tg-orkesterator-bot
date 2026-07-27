#!/bin/bash
set -e

echo "🚀 Initializing Orchestrator Environment...BY chaitanyabhave80"

# Pre-flight Check: Ensure Docker is installed
if ! command -v docker &>/dev/null; then
    echo "⚠️ Docker is not installed. Please install Docker before running the bot."
    exit 1
fi

# 1. Create directory hierarchy
mkdir -p tg-orkesterator-bot/{src,staging,templates}
cd tg-orkesterator-bot

# 2. Prompt for config and create environment variable configuration
echo -e "\n🔑 Please enter your Telegram Bot Token:"
read -r -s TELEGRAM_BOT_TOKEN
echo -e "\n✅ Token captured securely."

echo -e "\n👤 Please enter your allowed Telegram User ID(s) (comma-separated, e.g., 123456789):"
read -r ALLOWED_USER_IDS
echo -e "✅ User IDs captured."

cat << EOF > .env
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
MAX_MEMORY_LIMIT=256m
CPU_QUOTA_MICROSECONDS=50000
ALLOWED_USER_IDS=${ALLOWED_USER_IDS}
EOF

# Lock down .env permissions so other users cannot read the bot token
chmod 600 .env

# 3. Define project dependencies
cat << 'EOF' > requirements.txt
python-telegram-bot>=20.0
docker>=6.0.0
python-dotenv>=1.0.0
EOF

# 4. Create default hardened, non-root Dockerfile template with npm install support
cat << 'EOF' > templates/Dockerfile.template
FROM node:22-alpine

WORKDIR /app

# Copy only necessary files (exclude .env, staging, etc.)
COPY package*.json ./
RUN if [ -f package.json ]; then npm install --omit=dev; fi

COPY . .

# Create non-root user and assign permissions
RUN addgroup -S dalkergroup && adduser -S dalkeruser -G dalkergroup && \
    chown -R dalkeruser:dalkergroup /app

USER dalkeruser

CMD ["node", "index.js"]
EOF

# 5. Generate secure Python Orchestrator logic (with fixes)
cat << 'EOF' > src/bot.py
import os
import shutil
import zipfile
import logging
import docker
import time
import asyncio
import html
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    MessageHandler,
    filters,
    ContextTypes,
)

load_dotenv()

TELEGRAM_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")

# Setup Logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)

ALLOWED_USER_IDS = [
    int(uid.strip())
    for uid in os.getenv("ALLOWED_USER_IDS", "").split(",")
    if uid.strip().isdigit()
]

if not ALLOWED_USER_IDS:
    raise ValueError(
        "CRITICAL: ALLOWED_USER_IDS is missing or invalid in .env! "
        "Provide comma-separated Telegram user IDs (e.g., ALLOWED_USER_IDS=123456789)."
    )

STAGING_DIR = os.path.abspath("./staging")
TEMPLATES_DIR = os.path.abspath("./templates")

MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB limit
user_last_deploy = {}              # In-memory rate limiting state

# Initialize Docker Client
docker_client = docker.from_env()

def is_authorized(user_id: int) -> bool:
    return user_id in ALLOWED_USER_IDS

def safe_extract_zip(zip_file_path: str, extract_to_dir: str):
    """Prevents Zip Slip and Symlink attacks."""
    target_dir = os.path.abspath(extract_to_dir)
    with zipfile.ZipFile(zip_file_path, 'r') as zip_ref:
        for member in zip_ref.infolist():
            # Resolve the full path
            member_path = os.path.abspath(os.path.join(target_dir, member.filename))
            # Check path traversal
            if not (member_path == target_dir or member_path.startswith(target_dir + os.sep)):
                raise ValueError(f"Security Alert: Path Traversal detected in file: {member.filename}")

            # Check symlink – use is_symlink() if available, else fallback
            try:
                if member.is_symlink():
                    raise ValueError(f"Security Alert: Symlink detected in file: {member.filename}")
            except AttributeError:
                # Fallback for older Python versions
                import stat
                if stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError(f"Security Alert: Symlink detected in file: {member.filename}")

        zip_ref.extractall(target_dir)

def normalize_workspace(user_staging: str):
    """
    Flattens a single nested folder archive if index.js is inside a root folder.
    Also ensures that any stray Dockerfile is removed (we provide our own).
    """
    # Remove any existing Dockerfile that might have been in the zip
    dockerfile_path = os.path.join(user_staging, "Dockerfile")
    if os.path.exists(dockerfile_path):
        os.remove(dockerfile_path)

    if os.path.exists(os.path.join(user_staging, "index.js")):
        return

    subdirs = [
        os.path.join(user_staging, d)
        for d in os.listdir(user_staging)
        if os.path.isdir(os.path.join(user_staging, d))
    ]

    # If ZIP extracted into a single wrapper folder, pull contents up
    if len(subdirs) == 1:
        nested_dir = subdirs[0]
        if os.path.exists(os.path.join(nested_dir, "index.js")):
            for item in os.listdir(nested_dir):
                shutil.move(os.path.join(nested_dir, item), user_staging)
            os.rmdir(nested_dir)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        logging.warning(f"Unauthorized /start attempt from user ID: {user_id}")
        await update.message.reply_text("⛔ Unauthorized access.")
        return

    welcome_text = (
        "🛡️ *Orchestrator Online*\n\n"
        "*Usage Rules:*\n"
        "1. Send a `.zip` or `.js` file to stage your deployment.\n"
        "2. Run /deploy to provision your container.\n"
        "3. Run /status to check container health.\n"
        "4. Run /logs to inspect application output.\n"
        "5. Run /stop to kill active instances.\n"
        "6. Run /cleanup to sweep orphaned Docker resources."
    )
    await update.message.reply_text(welcome_text, parse_mode="Markdown")

async def handle_ingestion(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        logging.warning(f"Unauthorized upload attempt from user ID: {user_id}")
        await update.message.reply_text("⛔ Unauthorized access.")
        return

    document = update.message.document

    if document.file_size > MAX_FILE_SIZE:
        logging.warning(f"User {user_id} attempted to upload a file exceeding limit: {document.file_size} bytes")
        await update.message.reply_text(
            f"❌ File too large. Maximum size: 100MB. Your file: {document.file_size / (1024*1024):.1f}MB",
            parse_mode="Markdown"
        )
        return

    str_user_id = str(user_id)
    user_staging = os.path.join(STAGING_DIR, str_user_id)

    # Clean existing workspace
    shutil.rmtree(user_staging, ignore_errors=True)
    os.makedirs(user_staging, exist_ok=True)

    file_path = os.path.join(user_staging, document.file_name)
    file_obj = await context.bot.get_file(document.file_id)
    await file_obj.download_to_drive(file_path)

    logging.info(f"User {user_id} uploaded file '{document.file_name}' ({document.file_size} bytes)")

    if document.file_name.endswith('.zip'):
        try:
            await asyncio.to_thread(safe_extract_zip, file_path, user_staging)
            normalize_workspace(user_staging)
        except Exception as e:
            logging.error(f"ZIP extraction failed for user {user_id}: {str(e)}")
            shutil.rmtree(user_staging, ignore_errors=True)
            await update.message.reply_text(f"❌ Safe ingestion failed:\n`{str(e)}`", parse_mode="Markdown")
            return
        finally:
            if os.path.exists(file_path):
                os.remove(file_path)

    elif document.file_name.endswith('.js') and document.file_name != 'index.js':
        target_path = os.path.join(user_staging, "index.js")
        shutil.move(file_path, target_path)
    elif document.file_name == 'index.js':
        # Already in place
        pass
    else:
        shutil.rmtree(user_staging, ignore_errors=True)
        await update.message.reply_text("❌ Unsupported file type. Please upload a `.zip` or `.js` file.")
        return

    # Force overwrite Dockerfile with hardened template
    dockerfile_target = os.path.join(user_staging, "Dockerfile")
    shutil.copy(os.path.join(TEMPLATES_DIR, "Dockerfile.template"), dockerfile_target)

    await update.message.reply_text(
        f"📦 *Code Ingested Safely*\nStaging workspace ready for Telegram ID `{user_id}`.\nRun /deploy to start the container.",
        parse_mode="Markdown"
    )

async def deploy(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        logging.warning(f"Unauthorized /deploy attempt from user ID: {user_id}")
        await update.message.reply_text("⛔ Unauthorized access.")
        return

    str_user_id = str(user_id)

    # Rate Limiter: 5 seconds
    current_time = time.time()
    if str_user_id in user_last_deploy:
        if current_time - user_last_deploy[str_user_id] < 5:
            await update.message.reply_text("⏳ Please wait a few seconds before deploying again.")
            return
    user_last_deploy[str_user_id] = current_time

    user_staging = os.path.join(STAGING_DIR, str_user_id)
    container_name = f"dalker_user_{str_user_id}"
    network_name = f"dalker_net_{str_user_id}"
    image_tag = f"dalker_img_{str_user_id}"

    if not os.path.exists(user_staging):
        await update.message.reply_text("❌ No code package found. Please upload a `.zip` or `.js` file first.")
        return

    index_path = os.path.join(user_staging, "index.js")
    if not os.path.exists(index_path):
        await update.message.reply_text(
            "❌ Missing entry point!\nYour workspace must contain an `index.js` file at the root level.",
            parse_mode="Markdown"
        )
        return

    await update.message.reply_text("⚙️ Building hardened container... This may take up to 5 minutes.")

    try:
        # Cleanup existing running container instance
        try:
            old = await asyncio.to_thread(docker_client.containers.get, container_name)
            await asyncio.to_thread(old.stop)
            await asyncio.to_thread(old.remove, force=True)
        except docker.errors.NotFound:
            pass

        # Build isolated image with a hard timeout to prevent npm install hangs
        try:
            image, _ = await asyncio.wait_for(
                asyncio.to_thread(
                    docker_client.images.build,
                    path=user_staging,
                    tag=image_tag,
                    rm=True  # remove intermediate containers
                ),
                timeout=300
            )
        except asyncio.TimeoutError:
            await update.message.reply_text("❌ Build timed out. Ensure your dependencies install cleanly.", parse_mode="Markdown")
            return

        # Enforce private container bridge network per user, restricted from the host internal networks
        try:
            await asyncio.to_thread(docker_client.networks.get, network_name)
        except docker.errors.NotFound:
            await asyncio.to_thread(docker_client.networks.create, network_name, driver="bridge", internal=True)

        # Deploy container with quotas
        container = await asyncio.to_thread(
            docker_client.containers.run,
            image_tag,
            name=container_name,
            detach=True,
            network=network_name,
            mem_limit=os.getenv("MAX_MEMORY_LIMIT", "256m"),
            cpu_quota=int(os.getenv("CPU_QUOTA_MICROSECONDS", 50000)),
            restart_policy={"Name": "on-failure", "MaximumRetryCount": 3}
        )

        logging.info(f"Successfully deployed container '{container_name}' (ID: {container.short_id}) for user {user_id}")

        await update.message.reply_text(
            f"🚀 *Deployment Successful*\n\n"
            f"• *Container ID:* `{container.short_id}`\n"
            f"• *Network:* `{network_name}` (Internal)\n"
            f"• *Memory Cap:* `{os.getenv('MAX_MEMORY_LIMIT', '256m')}`\n"
            f"• *CPU Limit:* `{int(os.getenv('CPU_QUOTA_MICROSECONDS', 50000))/100000 * 100}%`",
            parse_mode="Markdown"
        )

    except docker.errors.BuildError as e:
        logging.error(f"Build failed for user {user_id}: {str(e)}")
        await update.message.reply_text("❌ Build failed. Check your Node.js code/dependencies for syntax errors.", parse_mode="Markdown")
    except docker.errors.DockerException as e:
        logging.error(f"Docker engine error during deploy for user {user_id}: {str(e)}")
        await update.message.reply_text("❌ Container engine error. Check daemon or permissions.", parse_mode="Markdown")
    except Exception as e:
        logging.error(f"Unexpected error during deploy for user {user_id}: {str(e)}")
        await update.message.reply_text("❌ Deployment failed due to an unexpected error.", parse_mode="Markdown")

async def status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        logging.warning(f"Unauthorized /status attempt from user ID: {user_id}")
        await update.message.reply_text("⛔ Unauthorized access.")
        return

    str_user_id = str(user_id)
    container_name = f"dalker_user_{str_user_id}"

    try:
        container = await asyncio.to_thread(docker_client.containers.get, container_name)
        status_msg = (
            f"🟢 *Container Active*\n\n"
            f"• *Name:* `{container.name}`\n"
            f"• *Status:* `{container.status}`\n"
            f"• *Created:* `{container.attrs['Created'][:19]}`"
        )
        await update.message.reply_text(status_msg, parse_mode="Markdown")
    except docker.errors.NotFound:
        await update.message.reply_text("🔴 No active deployment found associated with your user ID.")

async def logs_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        logging.warning(f"Unauthorized /logs attempt from user ID: {user_id}")
        await update.message.reply_text("⛔ Unauthorized access.")
        return

    str_user_id = str(user_id)
    container_name = f"dalker_user_{str_user_id}"

    try:
        container = await asyncio.to_thread(docker_client.containers.get, container_name)
        raw_logs = await asyncio.to_thread(container.logs, tail=100)

        # Parse mode HTML to avoid breaking Markdown rendering via unescaped special characters
        logs_text = html.escape(raw_logs.decode('utf-8', errors='ignore'))

        if len(logs_text) > 3500:
            logs_text = "⚠️ Logs truncated (too long):\n\n" + logs_text[-3500:]

        await update.message.reply_text(
            f"<b>📜 Container Logs:</b>\n<pre>{logs_text if logs_text else '(no output yet)'}</pre>",
            parse_mode="HTML"
        )
    except docker.errors.NotFound:
        await update.message.reply_text("🔴 No active deployment found to fetch logs from.")

async def stop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        logging.warning(f"Unauthorized /stop attempt from user ID: {user_id}")
        await update.message.reply_text("⛔ Unauthorized access.")
        return

    str_user_id = str(user_id)
    container_name = f"dalker_user_{str_user_id}"

    try:
        container = await asyncio.to_thread(docker_client.containers.get, container_name)
        await asyncio.to_thread(container.stop)
        await asyncio.to_thread(container.remove, force=True)
        logging.info(f"Container '{container_name}' stopped and removed by user {user_id}")
        await update.message.reply_text("🛑 Active container stopped and purged.")
    except docker.errors.NotFound:
        await update.message.reply_text("⚠️ No running instance found to stop.")

async def cleanup(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_authorized(user_id):
        logging.warning(f"Unauthorized /cleanup attempt from user ID: {user_id}")
        await update.message.reply_text("⛔ Unauthorized access.")
        return

    await update.message.reply_text("🧹 Sweeping orphaned Docker resources...")
    try:
        pruned_images = await asyncio.to_thread(docker_client.images.prune, filters={"dangling": True})
        await asyncio.to_thread(docker_client.networks.prune)

        reclaimed_space = (pruned_images or {}).get('SpaceReclaimed', 0) / (1024 * 1024)
        logging.info(f"User {user_id} triggered cleanup. Reclaimed {reclaimed_space:.1f} MB.")
        await update.message.reply_text(f"✅ Cleanup complete.\nReclaimed {reclaimed_space:.1f} MB of disk space.")
    except docker.errors.DockerException as e:
        logging.error(f"Cleanup failed: {str(e)}")
        await update.message.reply_text("❌ Cleanup encountered a Docker daemon error.")

if __name__ == "__main__":
    if not TELEGRAM_TOKEN or TELEGRAM_TOKEN == "YOUR_TELEGRAM_BOT_TOKEN_HERE":
        raise ValueError("Please set your TELEGRAM_BOT_TOKEN in the .env file.")

    app = ApplicationBuilder().token(TELEGRAM_TOKEN).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("deploy", deploy))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("logs", logs_cmd))
    app.add_handler(CommandHandler("stop", stop))
    app.add_handler(CommandHandler("cleanup", cleanup))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_ingestion))

    logging.info("🤖 Orchestrator service starting...")
    app.run_polling()
EOF

# 6. Setup Python environment and install dependencies
echo -e "\n📦 Setting up Python virtual environment and installing dependencies..."
if command -v python3 &>/dev/null; then
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
    echo "✅ Dependencies installed successfully."
else
    echo "⚠️ Python3 is not installed. Please install Python3 and pip manually."
    exit 1
fi

echo -e "\n✨ Setup complete! Make sure the Docker daemon is running."
echo "👉 To start the bot, run:"
echo "source venv/bin/activate && python src/bot.py"