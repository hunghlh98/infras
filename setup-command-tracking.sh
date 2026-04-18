#!/bin/bash
# Quick Setup Script for Command Tracking
# This script will add command tracking to your .zshrc

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER_FILE="$SCRIPT_DIR/.zsh-tracker.zsh"
ZSHRC="$HOME/.zshrc"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Command Tracking Setup                                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if tracker file exists
if [[ ! -f "$TRACKER_FILE" ]]; then
    echo "❌ Error: Tracker file not found at $TRACKER_FILE"
    exit 1
fi

# Check if already installed
if grep -q "zsh-tracker.zsh" "$ZSHRC" 2>/dev/null; then
    echo "✅ Command tracking is already installed in your .zshrc"
    echo ""
    echo "To re-install, first remove these lines from ~/.zshrc:"
    echo "  # Command tracking for /home/hunghlh/app/infras/"
    echo "  source /home/hunghlh/app/infras/.zsh-tracker.zsh"
    exit 0
fi

echo "This will add command tracking to your ~/.zshrc file."
echo ""
echo "What will be tracked:"
echo "  • All commands executed in /home/hunghlh/app/infras/"
echo "  • Timestamps, directories, git branches, exit codes"
echo "  • Command duration and success/failure status"
echo ""
echo "Logs will be stored in: /home/hunghlh/app/infras/.command-logs/"
echo ""

read -p "Do you want to proceed? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Setup cancelled."
    exit 0
fi

# Add tracking to .zshrc
echo ""
echo "📝 Adding command tracking to ~/.zshrc..."

{
    echo ""
    echo "# Command tracking for /home/hunghlh/app/infras/"
    echo "# Added: $(date)"
    echo "source $TRACKER_FILE"
} >> "$ZSHRC"

echo "✅ Setup complete!"
echo ""
echo "📋 Next Steps:"
echo "  1. Restart your shell or run: source ~/.zshrc"
echo "  2. Check it works: infras --help"
echo "  3. Try some commands and check: infras --stats"
echo ""
echo "📚 Full documentation: $SCRIPT_DIR/COMMAND_TRACKING_GUIDE.md"
echo ""
echo "🎯 Quick start commands:"
echo "  infras                 - Show help"
echo "  infras --stats         - Show statistics"
echo "  infras --recent        - Show recent commands"
echo "  infras --search <term> - Search command history"
echo "  infras --top           - Show most used commands"
echo ""
