#!/data/data/com.termux/files/usr/bin/bash
#
# calllog-range.sh -- Termux の着信履歴を指定期間ぶんだけ抽出する
#
# 使い方:
#   bash calllog-range.sh                      # 既定: 2026-03-03 から2ヶ月分
#   bash calllog-range.sh 2026-03-03 2026-05-03   # 開始日 終了日(この日は含まない)
#
# 事前準備:
#   1) Termux:API アプリ(F-Droid 版)をインストール
#   2) pkg install termux-api jq
#   3) Android の 設定 > アプリ > Termux:API > 権限 > 通話履歴 を許可
#
set -euo pipefail

START="${1:-2026-03-03}"
END="${2:-2026-05-03}"          # 終了日は含まない (排他)

PAGE=200                         # 1回の取得件数
MAX=5000                         # 安全のための上限
OUTDIR="${HOME}/calllog"
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="${OUTDIR}/raw-${STAMP}.json"
OUT_JSON="${OUTDIR}/calllog-${START}_${END}.json"
OUT_CSV="${OUTDIR}/calllog-${START}_${END}.csv"

command -v termux-call-log >/dev/null || {
  echo "エラー: termux-call-log が見つかりません。 pkg install termux-api を実行してください。" >&2; exit 1; }
command -v jq >/dev/null || {
  echo "エラー: jq が見つかりません。 pkg install jq を実行してください。" >&2; exit 1; }

mkdir -p "$OUTDIR"

echo "== 通話履歴を取得中 (新しい順にページング) =="
echo '[]' > "$RAW"
offset=0
while [ "$offset" -lt "$MAX" ]; do
  page="$(termux-call-log -l "$PAGE" -o "$offset" 2>/dev/null || echo '[]')"

  # 権限が無いと空配列やエラーになる。最初のページが空なら中断。
  count="$(printf '%s' "$page" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$count" -eq 0 ]; then
    [ "$offset" -eq 0 ] && echo "警告: 履歴が0件です。Termux:API の「通話履歴」権限を確認してください。" >&2
    break
  fi

  jq -s 'add' "$RAW" <(printf '%s' "$page") > "${RAW}.tmp" && mv "${RAW}.tmp" "$RAW"
  echo "  offset=${offset} で ${count} 件取得"

  # このページの最古の日付が開始日より前なら、これ以上さかのぼる必要はない
  oldest="$(printf '%s' "$page" | jq -r '[.[].date] | min // ""')"
  if [ -n "$oldest" ] && [ "${oldest:0:10}" \< "$START" ]; then
    echo "  最古 ${oldest} が開始日より前 -> 取得終了"
    break
  fi

  offset=$((offset + PAGE))
  [ "$count" -lt "$PAGE" ] && { echo "  端末の履歴を全件読み終えました"; break; }
done

total_raw="$(jq 'length' "$RAW")"
echo "取得件数(全体): ${total_raw}"

# --- 期間で絞り込み。date は "YYYY-MM-DD HH:MM:SS" 形式なので文字列比較でよい ---
jq --arg s "$START" --arg e "$END" '
  map(select(.date[0:10] >= $s and .date[0:10] < $e))
  | sort_by(.date)
' "$RAW" > "$OUT_JSON"

n="$(jq 'length' "$OUT_JSON")"

# --- CSV 出力 ---
{
  echo "日時,種別,相手先名,電話番号,通話時間,SIM"
  jq -r '.[] | [.date, .type, (.name // ""), .phone_number, .duration, (.sim_id // "")] | @csv' "$OUT_JSON"
} > "$OUT_CSV"

echo
echo "================ 集計 (${START} 〜 ${END} の前日まで) ================"
echo "該当件数: ${n} 件"
if [ "$n" -gt 0 ]; then
  echo
  echo "-- 種別ごとの件数 --"
  jq -r 'group_by(.type)[] | "\(.[0].type)\t\(length) 件"' "$OUT_JSON" | sort -k2 -rn
  echo
  echo "-- 着信(INCOMING/MISSED)の相手先 上位20 --"
  jq -r '
    map(select(.type == "INCOMING" or .type == "MISSED"))
    | group_by(.phone_number)[]
    | "\(length)\t\(.[0].phone_number)\t\(.[0].name // "(名前なし)")"
  ' "$OUT_JSON" | sort -rn | head -20
  echo
  echo "-- 月別の件数 --"
  jq -r 'group_by(.date[0:7])[] | "\(.[0].date[0:7])\t\(length) 件"' "$OUT_JSON"
  echo
  echo "-- 明細 --"
  jq -r '.[] | "\(.date)  \(.type)  \(.phone_number)  \(.duration)  \(.name // "")"' "$OUT_JSON"
fi

echo
echo "保存先:"
echo "  JSON: $OUT_JSON"
echo "  CSV : $OUT_CSV"
echo "  生データ: $RAW"
