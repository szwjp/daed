#!/usr/bin/env bash
# 本 fork 自有改动的指纹校验。
#
# 同一份清单在 check-upstream.yml 里被跑两次：
#   (a) bump push 之前（custom_check）
#   (b) merge 上游 daed 之后（Verify custom changes survived merge）
# 放在这里共用，避免两处清单漂移；项数由脚本自己数，文档不再重复计数。
#
# 用法：仓库根目录下 `bash hack/check-fork-customizations.sh`（已在 CI 里这么用）
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

MISSING=""
TOTAL=0

check() { # $1=文件 $2=必须出现的字符串
  TOTAL=$((TOTAL + 1))
  grep -q "$2" "$1" 2>/dev/null || MISSING="$MISSING $1($2)"
}

check README.md                              'szwjp/daed'
check apps/web/src/components/Header.tsx     'general.dae.version'
check apps/web/src/i18n/locales/zh-Hans.json 'coreVersion'
check apps/web/src/i18n/locales/en.json      'coreVersion'
check apps/web/src/contexts/index.tsx        'DEFAULT_ENDPOINT_URL'
check apps/web/src/pages/Setup.tsx           'endpoint unreachable'
check .github/workflows/build-custom.yml     'Assert dae-core pin matches dae main'

# release-please.yml 必须保持删除：fork 里的 Actions 无权创建 PR
TOTAL=$((TOTAL + 1))
[ -e .github/workflows/release-please.yml ] && MISSING="$MISSING .github/workflows/release-please.yml(被恢复)"

if [ -n "$MISSING" ]; then
  echo "::error::自有改动指纹缺失:$MISSING"
  exit 1
fi

echo "自有改动指纹 $TOTAL 项全部在位"
