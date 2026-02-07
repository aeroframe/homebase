#!/usr/bin/env bash
set -e
sudo systemctl stop dump978-fa || true
sudo systemctl start dump1090-fa
echo "Homebase ADS-B mode: 1090"