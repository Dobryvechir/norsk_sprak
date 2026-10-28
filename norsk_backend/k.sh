#!/bin/sh
# The app runs as the systemd service "movna" (see /etc/systemd/system/movna.service).
systemctl restart movna
systemctl --no-pager status movna | head -5
