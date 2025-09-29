#!/bin/bash
cd ~/.notes 
git pull origin master
git add .
git commit -m "Auto-commit $(date +%Y-%m-%d)"
git push origin master
