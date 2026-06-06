from pathlib import Path
text = Path('tests/reports/current.log').read_text(encoding='utf-16')
for i, l in enumerate(text.splitlines(), 1):
    if 'failed:' in l or 'expected ' in l or 'found ' in l:
        print(f'{i}: {l}')
