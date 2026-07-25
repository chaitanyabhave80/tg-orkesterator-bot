# tg-orkesterator-bot

🤖 **tg-orkesterator-bot** is a Telegram-based deployment orchestrator. Users upload `.zip` or `.js` files to the bot, which automatically provisions and runs the code inside secure, isolated Docker containers. It enforces strict CPU and memory limits per user, with an automated setup script handling dependencies and environment variables.

## ✨ Features
- **Telegram Integration:** Control your deployments directly from Telegram.
- **Automated Setup:** Interactive `setup.sh` handles API key configuration, virtual environment setup, and dependency installation.
- **Container Isolation:** Every user gets a private Docker bridge network and isolated container instance.
- **Resource Quotas:** Hard limits on memory (256MB) and CPU usage to prevent abuse.
- **Secure by Default:** Runs Node.js deployments using a hardened, non-root Alpine Docker template.

## 📋 Prerequisites
- **Docker:** Must be installed and running on your host machine.
- **Python 3.x:** Required for the orchestrator bot.
- **Telegram Bot Token:** Obtain one from [@BotFather](https://t.me/BotFather) on Telegram.

## 🚀 Installation

1. Make the setup script executable (if you have saved it as `setup.sh`):
   ```bash
   chmod +x setup.sh
   ```
2. Run the initialization script:
   ```bash
   ./setup.sh
   ```
   *The script will prompt you for your Telegram Bot Token, set up the directory structure (`tg-orkesterator-bot/`), and install all Python dependencies in an isolated virtual environment.*

## 💻 Usage

1. Start the bot service:
   ```bash
   cd tg-orkesterator-bot
   source venv/bin/activate
   python src/bot.py
   ```

2. Open Telegram and interact with your bot using the following commands:
   - `/start` - View usage rules and bot information.
   - **Send a file** - Upload a `.zip` (containing your code and entry point) or a standalone `.js` file to stage your deployment.
   - `/deploy` - Build the image and provision your isolated container.
   - `/status` - Check the real-time health and status of your active container.
   - `/stop` - Stop and purge your current running instance.

## 🔒 Security Notes
Code uploaded to this bot is run in a secure sandbox. The default `Dockerfile.template` drops root privileges and runs as `dalkeruser`. Existing running instances for a specific user are automatically cleaned up before a new deployment begins.
