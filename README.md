# tg-orkesterator-bot

🤖 **tg-orkesterator-bot** is a Telegram-based deployment orchestrator. Users upload `.zip` or `.js` files to the bot, which automatically provisions and runs the code inside secure, isolated Docker containers with strict resource quotas and real-time debugging.

## ✨ Features

- **Telegram Integration:** Control deployments directly from Telegram with intuitive commands.
- **Automated Setup:** Interactive `setup.sh` handles API key configuration, virtual environment setup, and dependency installation—**no manual `.env` editing required**.
- **Container Isolation:** Every user gets a private Docker bridge network and isolated container instance.
- **Resource Quotas:** Hard limits on memory (256MB) and CPU usage (50% by default) to prevent abuse.
- **Secure by Default:** 
  - Runs Node.js 22-alpine (LTS, fast, secure)
  - Non-root containers (drops to `dalkeruser`)
  - Zip Slip prevention (path traversal attacks blocked)
  - `.env` secured with `chmod 600` (token readable only by owner)
- **Rate Limiting:** 5-second cooldown between deployments per user
- **File Size Protection:** 100MB upload limit to prevent disk exhaustion
- **Real-Time Debugging:** `/logs` command to inspect application output directly from Telegram
- **Resource Cleanup:** `/cleanup` command to sweep orphaned Docker images and networks
- **Non-Blocking I/O:** Asyncio-threaded operations for true concurrency

## 📋 Prerequisites

- **Docker:** Must be installed and running on your host machine.
- **Python 3.x:** Required for the orchestrator bot.
- **Telegram Bot Token:** Obtain one from [@BotFather](https://t.me/BotFather) on Telegram.
- **Your Telegram User ID:** Get it from [@userinfobot](https://t.me/userinfobot) on Telegram.

## 🚀 Installation

1. Clone or download the repository:
   ```bash
   git clone https://github.com/chaitanyabhave80/tg-orkesterator-bot.git
   cd tg-orkesterator-bot
   ```

2. Make the setup script executable:
   ```bash
   chmod +x setup.sh
   ```

3. Run the initialization script:
   ```bash
   ./setup.sh
   ```
   - The script will check for Docker
   - Prompt you for your **Telegram Bot Token** (input securely, no echo)
   - Prompt you for your **allowed Telegram User ID(s)** (comma-separated)
   - Set up the directory structure (`tg-orkesterator-bot/`)
   - Create a hardened `.env` file (permissions: `600`)
   - Install all Python dependencies in an isolated virtual environment

## 💻 Usage

1. Start the bot service:
   ```bash
   cd tg-orkesterator-bot
   source venv/bin/activate
   python src/bot.py
   ```

2. Open Telegram and interact with your bot using the following commands:

   | Command | Purpose |
   |---------|---------|
   | `/start` | View usage rules and list all available commands |
   | **Send a file** | Upload a `.zip` (with `index.js` entry point) or a standalone `.js` file to stage your deployment |
   | `/deploy` | Build the Docker image and provision your isolated container with resource quotas |
   | `/status` | Check the real-time health and status of your active container |
   | `/logs` | Inspect the last 100 lines of your container's output (useful for debugging crashes) |
   | `/stop` | Stop and remove your active container instance |
   | `/cleanup` | Sweep orphaned Docker images and networks (reclaim disk space) |

## 🔒 Security Notes

### Container Sandboxing
- Code uploaded to this bot runs in a **secure sandbox** with:
  - Non-root user (`dalkeruser`) with dropped privileges
  - Private Docker bridge network per user (no inter-container communication)
  - Memory limit: 256MB (configurable in `.env`)
  - CPU limit: 50% (configurable in `.env`)
  - Automatic restart on failure (max 3 retries)

### Path Traversal Prevention
- Zip files are extracted with **Zip Slip protection**
  - Files attempting path traversal (`../../etc/passwd`) are blocked
  - Extraction validates that all paths stay within the user's staging directory

### Token Protection
- `.env` file is automatically secured with `chmod 600` permissions
- Only readable by the bot process owner
- Prevents other system users from accessing your Telegram token

### Authorization
- Whitelist-based access control
- Only specified Telegram user IDs can upload, deploy, or view logs
- Unauthorized attempts are logged

## 📦 Auto-Rename Feature

If you upload a standalone `.js` file (e.g., `myapp.js`), the bot automatically renames it to `index.js` so the Dockerfile `CMD ["node", "index.js"]` works correctly.

**Before:** Had to manually name files `index.js`  
**After:** Upload any `.js` file, bot handles it

## 📊 Monitoring & Debugging

### Real-Time Logs
```
/logs
```
Returns the last 100 lines of your container's stdout/stderr. Perfect for debugging:
- SyntaxError in your Node.js code
- Missing dependencies
- Application crashes

Logs are truncated to Telegram's 4096-character limit, so you get the most recent output.

### Resource Usage
```
/status
```
Shows:
- Container name
- Current status (`running`, `exited`, etc.)
- Timestamp of when it was created

## ⚙️ Configuration

Edit `tg-orkesterator-bot/.env` to customize:
```env
TELEGRAM_BOT_TOKEN=your_token_here
MAX_MEMORY_LIMIT=256m          # Container memory cap (e.g., 512m, 1g)
CPU_QUOTA_MICROSECONDS=50000   # CPU limit in microseconds (50000 = 50%)
ALLOWED_USER_IDS=123456789,987654321  # Comma-separated Telegram user IDs
```

## 🐳 Docker Base Image

The bot uses **Node.js 22-alpine** as the base image:
- **22:** Latest LTS version (supported until April 2026)
- **alpine:** Minimal, fast, secure (~150MB vs 900MB for full Node image)
- **Non-root:** Runs as `dalkeruser` (not `root`)

## 🛠️ Troubleshooting

| Issue | Solution |
|-------|----------|
| "Docker is not installed" | Install Docker from [docker.com](https://www.docker.com/products/docker-desktop) |
| "Unauthorized access" | Ensure your Telegram user ID is in `ALLOWED_USER_IDS` in `.env` |
| `/deploy` takes forever | Docker image builds can take 30-60 seconds on first run. Subsequent builds are faster. |
| Container crashes immediately | Use `/logs` to see the error. Check your Node.js code for syntax errors or missing dependencies. |
| "File too large" | Maximum upload is 100MB. Compress your code or remove large files. |

## 📄 License

Apache License 2.0 – See [LICENSE.txt](LICENSE.txt) for details.

## 🙏 Contributing

Found a bug? Have a feature request?
- Open an issue on GitHub
- Submit a pull request

## 👨‍💻 Author

Developed by **chaitanyabhave80**

---

**Happy deploying! 🚀**