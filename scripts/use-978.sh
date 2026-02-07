#!/usr/bin/env bash
set -e
sudo systemctl stop dump1090-fa || true
sudo systemctl start dump978-fa
echo "Homebase ADS-B mode: 978"