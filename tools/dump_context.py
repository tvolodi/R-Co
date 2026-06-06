from pathlib import Path
text = Path('tests/reports/current.log').read_text(encoding='utf-16')
lines = text.splitlines()
for start in (13, 2371, 4729):
    print('\n---LINE', start, '---')
    for i in range(max(1, start - 5), min(len(lines), start + 25) + 1):
        print(f'{i}: {lines[i - 1]}')
