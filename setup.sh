#!/bin/bash
set -e

echo "🚀 Initializing Orchestrator Environment..."

# 1. Create directory hierarchy with new name
mkdir -p tg-orkesterator-bot/{src,staging,vault,templates}
cd tg-orkesterator-bot

# 2. Prompt for API Key and create environment variable configuration
echo -e "\n🔑 Please enter your Telegram Bot Token:"
read -r -s TELEGRAM_BOT_TOKEN
echo -e "\n✅ Token captured securely."

# Notice the unquoted EOF here so the bash variable expands into the file
cat << EOF > .env
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
MAX_MEMORY_LIMIT=256m
CPU_QUOTA_MICROSECONDS=50000
EOF

# 3. Define project dependencies
# Using quoted 'EOF' for the rest so internal syntax isn't modified by Bash
cat << 'EOF' > requirements.txt
python-telegram-bot>=20.0
docker>=6.0.0
python-dotenv>=1.0.0
EOF

# 4. Create default hardened, non-root Dockerfile template
cat << 'EOF' > templates/Dockerfile.template
# Hardened Base Container
FROM node:18-alpine

# Create non-root user and set permissions
RUN addgroup -S dalkergroup && adduser -S dalkeruser -G dalkergroup
WORKDIR /app
COPY . .
RUN chown -R dalkeruser:dalkergroup /app

# Drop root permissions
USER dalkeruser

CMD ["node", "index.js"]
EOF

# 5. Generate core Python Orchestrator logic
cat << 'EOF' > src/bot.py
import os
import shutil
import zipfile
import logging
import docker
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
STAGING_DIR = os.path.abspath("./staging")
VAULT_DIR = os.path.abspath("./vault")
TEMPLATES_DIR = os.path.abspath("./templates")

# Initialize Docker Client
docker_client = docker.from_env()

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    welcome_text = (
        "🛡️ *Orchestrator Online*\n\n"
        "*Usage Rules:*\n"
        "1. Send a `.zip` or `.js` file to stage your deployment.\n"
        "2. Run /deploy to build and provision your container.\n"
        "3. Run /status to check resource usage and health.\n"
        "4. Run /stop to kill active instances."
    )
    await update.message.reply_text(welcome_text, parse_mode="Markdown")

async def handle_ingestion(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Processes uploaded files and isolates them by Telegram User ID."""
    user_id = str(update.effective_user.id)
    document = update.message.document
    
    user_staging = os.path.join(STAGING_DIR, user_id)
    os.makedirs(user_staging, exist_ok=True)

    file_path = os.path.join(user_staging, document.file_name)
    file_obj = await context.bot.get_file(document.file_id)
    await file_obj.download_to_drive(file_path)

    # Extract ZIP packages
    if document.file_name.endswith('.zip'):
        with zipfile.ZipFile(file_path, 'r') as zip_ref:
            zip_ref.extractall(user_staging)
        os.remove(file_path)

    # Attach hardened non-root Dockerfile if not explicitly provided
    dockerfile_target = os.path.join(user_staging, "Dockerfile")
    if not os.path.exists(dockerfile_target):
        shutil.copy(os.path.join(TEMPLATES_DIR, "Dockerfile.template"), dockerfile_target)

    await update.message.reply_text(
        f"📦 *Code Ingested*\nStaging workspace ready for Telegram ID `{user_id}`.\nRun /deploy to run the container.",
        parse_mode="Markdown"
    )

async def deploy(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Builds and runs isolated container with resource hard limits."""
    user_id = str(update.effective_user.id)
    user_staging = os.path.join(STAGING_DIR, user_id)
    container_name = f"dalker_user_{user_id}"

    if not os.path.exists(user_staging):
        await update.message.reply_text("❌ No code package found. Please upload a `.zip` or `.js` file first.")
        return

    await update.message.reply_text("⚙️ Building hardened container...")

    try:
        # Cleanup existing running container instance if present
        try:
            old = docker_client.containers.get(container_name)
            old.stop()
            old.remove()
        except docker.errors.NotFound:
            pass

        # Build isolated image
        image, _ = docker_client.images.build(path=user_staging, tag=f"dalker_img_{user_id}")

        # Enforce private container bridge network per user
        network_name = f"dalker_net_{user_id}"
        try:
            docker_client.networks.get(network_name)
        except docker.errors.NotFound:
            docker_client.networks.create(network_name, driver="bridge")

        # Deploy container with quotas
        container = docker_client.containers.run(
            image.id,
            name=container_name,
            detach=True,
            network=network_name,
            mem_limit=os.getenv("MAX_MEMORY_LIMIT", "256m"),
            cpu_quota=int(os.getenv("CPU_QUOTA_MICROSECONDS", 50000)),
            restart_policy={"Name": "on-failure", "MaximumRetryCount": 3}
        )

        await update.message.reply_text(
            f"🚀 *Deployment Successful*\n\n"
            f"• *Container ID:* `{container.short_id}`\n"
            f"• *Network:* `{network_name}`\n"
            f"• *Memory Cap:* `{os.getenv('MAX_MEMORY_LIMIT', '256m')}`\n"
            f"• *CPU Limit:* `{int(os.getenv('CPU_QUOTA_MICROSECONDS', 50000))/100000 * 100}%`",
            parse_mode="Markdown"
        )
    except Exception as e:
        await update.message.reply_text(f"❌ Deployment failed:\n`{str(e)}`", parse_mode="Markdown")

async def status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Retrieves real-time container health metrics."""
    user_id = str(update.effective_user.id)
    container_name = f"dalker_user_{user_id}"

    try:
        container = docker_client.containers.get(container_name)
        status_msg = (
            f"🟢 *Container Active*\n\n"
            f"• *Name:* `{container.name}`\n"
            f"• *Status:* `{container.status}`\n"
            f"• *Created:* `{container.attrs['Created'][:19]}`"
        )
        await update.message.reply_text(status_msg, parse_mode="Markdown")
    except docker.errors.NotFound:
        await update.message.reply_text("🔴 No active deployment found associated with your user ID.")

async def stop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Stops and removes active container instance."""
    user_id = str(update.effective_user.id)
    container_name = f"dalker_user_{user_id}"

    try:
        container = docker_client.containers.get(container_name)
        container.stop()
        container.remove()
        await update.message.reply_text("🛑 Active container stopped and purged.")
    except docker.errors.NotFound:
        await update.message.reply_text("⚠️ No running instance found to stop.")

if __name__ == "__main__":
    if not TELEGRAM_TOKEN or TELEGRAM_TOKEN == "YOUR_TELEGRAM_BOT_TOKEN_HERE":
        raise ValueError("Please set your TELEGRAM_BOT_TOKEN in the .env file.")

    app = ApplicationBuilder().token(TELEGRAM_TOKEN).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("deploy", deploy))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("stop", stop))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_ingestion))

    print("🤖 Orchestrator service starting...")
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
fi

echo -e "\n✨ Setup complete! Make sure Docker is running."
echo "👉 To start the bot, run:"
echo "cd tg-orkesterator-bot && source venv/bin/activate && python src/bot.py"
