# Copyright 2026 Breeze Core contributors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit acct-user

DESCRIPTION="User for the Breeze Core service"
ACCT_USER_ID=-1
ACCT_USER_GROUPS=( breeze )
ACCT_USER_HOME=/etc/breeze-core
ACCT_USER_SHELL=/sbin/nologin

acct-user_add_deps
