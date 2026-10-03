#!/usr/bin/env bash
# Publishes SpaceKeeper to a new PUBLIC GitHub repository.
#
#   bash publish_to_github.sh              -> repository named "SpaceKeeper"
#   bash publish_to_github.sh MyRepoName   -> choose another name
#
# What it does, step by step:
#   1. Installs the GitHub command-line tool (gh) with Homebrew if needed.
#   2. Signs you in to GitHub in your web browser (first time only).
#   3. Turns this folder into a Git repository and makes the first commit.
#      Commits use your GitHub "noreply" email, so your real email address
#      is never published.
#   4. Creates the repository on GitHub and uploads the code.
#   5. Turns on the project website (GitHub Pages, from the docs/ folder).
# Running it again later uploads any new commits instead.
set -euo pipefail
cd "$(dirname "$0")"

REPO_NAME="${1:-SpaceKeeper}"
DESCRIPTION="macOS menu bar utility to name, pin, reorder, add and remove Mission Control Spaces (Swift 6, SwiftUI)."

# 1. Tools
if ! command -v git >/dev/null 2>&1; then
  echo "Git isn't installed. Run: xcode-select --install   then run this script again."
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "> Installing the GitHub command-line tool (gh)..."
    brew install gh
  else
    echo "The GitHub command-line tool (gh) is needed."
    echo "Install Homebrew from https://brew.sh (then run this script again),"
    echo "or download gh from https://cli.github.com"
    exit 1
  fi
fi

# 2. Sign in
if ! gh auth status >/dev/null 2>&1; then
  echo "> Signing in to GitHub (a browser window will open)..."
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git >/dev/null 2>&1 || true
LOGIN="$(gh api user --jq .login)"
USER_ID="$(gh api user --jq .id)"
FULL_NAME="$(gh api user --jq '.name // .login')"

# 3. Local repository and first commit
if [ ! -d .git ]; then
  git init -b main >/dev/null
fi
# Identity for THIS repository only, using GitHub's private noreply address.
git config user.name "${FULL_NAME}"
git config user.email "${USER_ID}+${LOGIN}@users.noreply.github.com"

git add -A
if git diff --cached --quiet; then
  echo "> Nothing new to commit."
else
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git commit -m "Update SpaceKeeper" >/dev/null
  else
    git commit -m "Initial commit: SpaceKeeper menu bar utility" >/dev/null
  fi
  echo "> Committed: $(git log -1 --pretty=%s)"
fi

# 4. Create on GitHub (first time) or push (later)
if git remote get-url origin >/dev/null 2>&1; then
  echo "> Uploading to $(git remote get-url origin)..."
  git push -u origin main
else
  echo "> Creating public repository ${LOGIN}/${REPO_NAME} on GitHub..."
  gh repo create "${REPO_NAME}" --public --description "${DESCRIPTION}" \
    --source . --remote origin --push
fi

# 5. Website: publish the docs/ folder with GitHub Pages (free for public repos)
SITE_URL="https://${LOGIN}.github.io/${REPO_NAME}/"
if [ -f docs/index.html ]; then
  echo "> Turning on the website (GitHub Pages from the docs folder)..."
  if ! gh api "repos/${LOGIN}/${REPO_NAME}/pages" >/dev/null 2>&1; then
    gh api -X POST "repos/${LOGIN}/${REPO_NAME}/pages" \
      -f "source[branch]=main" -f "source[path]=/docs" >/dev/null 2>&1 \
      || echo "  Couldn't turn on Pages automatically. On GitHub: Settings > Pages > Branch: main, folder: /docs > Save."
  fi
  gh repo edit "${LOGIN}/${REPO_NAME}" --homepage "${SITE_URL}" >/dev/null 2>&1 || true
fi

echo ""
echo "Done!"
echo "  Code:    https://github.com/${LOGIN}/${REPO_NAME}"
echo "  Website: ${SITE_URL}  (the first build can take a minute or two)"
