#!/bin/bash

GH_USER="chaitanyabhave80"
GH_EMAIL="chaitanyabhave80@gmail.com"
REPO="github.com/chaitanyabhave80/tg-orkesterator-bot.git"

# Set Git Identity
git config user.name "$GH_USER"
git config user.email "$GH_EMAIL"

# If token isn't saved yet, ask for it once
if [ ! -f .gh_token ]; then
    echo "=========================================="
    echo "PASTE YOUR GITHUB TOKEN BELOW AND PRESS ENTER:"
    echo "=========================================="
    read TOKEN
    echo "$TOKEN" | tr -d ' \t\n\r' > .gh_token
    
    # Keep token safe from public Git uploads
    grep -qxF '.gh_token' .gitignore 2>/dev/null || echo '.gh_token' >> .gitignore
fi

# Load saved token
TOKEN=$(cat .gh_token)

# Link repository using token
git remote set-url origin "https://${TOKEN}@${REPO}"

# Run automated push
git add .
git commit -m "Automated update: $(date +'%Y-%m-%d %H:%M:%S')"
git branch -M main
git push -u origin main

echo "=========================================="
echo " SUCCESS! All files pushed to GitHub."
echo "=========================================="
