#!/usr/bin/env bash
# Tails the mock WhatsApp service and renders each outgoing message the way a
# real recipient would see it, instead of raw echoed JSON. Handy for demos —
# run this in a terminal alongside the OpenMRS/ERPNext browser tabs.
set -euo pipefail

TEMPLATES=$(cat <<'EOF'
{
  "ncd_referral_hc_notify": "Hello {0}, a new NCD referral has been submitted from the community screening programme. Patient: {1} · DOB: {2} · Screened at: {3} on {4} · Condition: {5} · OpenMRS ID: {6}. Please expect this patient for follow-up. — NCD Community Screening Programme",
  "ncd_referral_patient_notify": "Dear {0}, during your health screening on {1} our team identified a condition requiring follow-up care. Please visit {2} as soon as possible. Bring this message when you go. — NCD Community Screening Programme"
}
EOF
)

docker logs -f --tail 0 ncd-dev-env-mock-whatsapp-1 2>/dev/null | python3 -u -c "
import sys, json

templates = json.loads('''$TEMPLATES''')
buf = []
capturing = False

for line in sys.stdin:
    stripped = line.rstrip('\n')
    if stripped == '{':
        buf = [stripped]
        capturing = True
        continue
    if capturing:
        buf.append(stripped)
        if stripped == '}':
            capturing = False
            try:
                req = json.loads('\n'.join(buf))
            except Exception:
                continue
            body = req.get('json')
            if not isinstance(body, dict) or 'template' not in body:
                continue
            to = body.get('to', '?')
            tpl = body['template']
            name = tpl.get('name', '?')
            params = [p.get('text', '') for p in tpl.get('components', [{}])[0].get('parameters', [])]
            text = templates.get(name)
            if text:
                for i, val in enumerate(params):
                    text = text.replace('{%d}' % i, str(val))
            else:
                text = f'(unknown template {name}) params={params}'
            print('=' * 70)
            print(f'WhatsApp -> {to}')
            print(f'Template: {name}')
            print('-' * 70)
            print(text)
            print()
"
