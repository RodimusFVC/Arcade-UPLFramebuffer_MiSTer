# -*- coding: utf-8 -*-
"""Generate UPL Framebuffer MRAs straight from MAME's ninjakd2.cpp.
Every CRC, offset, length, DIP name and DIP id is taken from the driver."""
import re, io, os, sys

SRC = "/Work/Projects/Arcade-UPLFramebuffer_MiSTer/Useful Information/mame/ninjakd2.cpp"
OUT = "/Work/Projects/Arcade-UPLFramebuffer_MiSTer/releases"
s = io.open(SRC, encoding='utf-8', errors='ignore').read()

def num(x):
    x = x.strip()
    m = re.fullmatch(r'([0-9]+)\s*\*\s*(0x[0-9a-fA-F]+|[0-9]+)', x)
    if m: return int(m.group(1)) * int(m.group(2), 0)
    return int(x, 0)

# ---------------------------------------------------------------- ROMs
roms = {}
for m in re.finditer(r'ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END', s, re.S):
    g, body = m.group(1), m.group(2)
    regions, cur, last = {}, None, None
    for line in body.split('\n'):
        line = re.sub(r'//.*', '', line)
        r = re.search(r'ROM_REGION\(\s*([^,]+),\s*"([^"]+)"', line)
        if r:
            cur = r.group(2); regions[cur] = {'size': num(r.group(1)), 'segs': []}; continue
        r = re.search(r'ROM_LOAD\w*\(\s*"([^"]+)"\s*,\s*([^,]+),\s*([^,]+),\s*CRC\(([0-9a-fA-F]+)\)', line)
        if r and cur:
            last = {'file': r.group(1), 'crc': r.group(4), 'dst': num(r.group(2)),
                    'len': num(r.group(3)), 'src': 0}
            regions[cur]['segs'].append(last); continue
        r = re.search(r'ROM_CONTINUE\(\s*([^,]+),\s*([^)]+)\)', line)
        if r and last:
            seg = {'file': last['file'], 'crc': last['crc'], 'dst': num(r.group(1)),
                   'len': num(r.group(2)), 'src': last['src'] + last['len']}
            regions[cur]['segs'].append(seg); last = seg
    roms[g] = regions

# ---------------------------------------------------------------- GAME() metadata
meta = {}
for m in re.finditer(r'GAME\(\s*(\d{4}),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*\w+,\s*\w+,\s*(ROT\d+),\s*"([^"]*)",\s*"((?:[^"\\]|\\.)*)"', s):
    meta[m.group(2)] = dict(year=m.group(1), parent=m.group(3), machine=m.group(4),
                            ports=m.group(5), rot=m.group(6), mfr=m.group(7), full=m.group(8))

# ---------------------------------------------------------------- INPUT_PORTS / DIPs
blocks = {m.group(1): m.group(2) for m in
          re.finditer(r'INPUT_PORTS_START\(\s*(\w+)\s*\)(.*?)INPUT_PORTS_END', s, re.S)}

DEF = {'Off':'Off','On':'On','Yes':'Yes','No':'No','None':'None','Normal':'Normal','Hard':'Hard',
       'Easy':'Easy','Hardest':'Hardest','Harder':'Harder','English':'English','Japanese':'Japanese',
       'Upright':'Upright','Cocktail':'Cocktail','Unused':'Unused','Unknown':'Unknown',
       'Flip_Screen':'Flip Screen','Bonus_Life':'Bonus Life','Allow_Continue':'Allow Continue',
       'Demo_Sounds':'Demo Sounds','Difficulty':'Difficulty','Lives':'Lives','Language':'Language',
       'Cabinet':'Cabinet','Coin_A':'Coin A','Coin_B':'Coin B','Coinage':'Coinage',
       'Free_Play':'Free Play','Service_Mode':'Service Mode','Very_Hard':'Very Hard'}
def defstr(t):
    t = t.strip()
    m = re.fullmatch(r'DEF_STR\(\s*([\w./]+)\s*\)', t)
    if m:
        k = m.group(1)
        if k in DEF: return DEF[k]
        c = re.fullmatch(r'(\d+)C_(\d+)C', k)
        if c:
            a, b = int(c.group(1)), int(c.group(2))
            return "%d Coin%s/%d Credit%s" % (a, '' if a == 1 else 's', b, '' if b == 1 else 's')
        return k.replace('_', ' ')
    return t.strip('"')

def dips_for(name):
    """Return {port: [ (mask, default, label, {value:text}) ]} with PORT_INCLUDE resolved."""
    body = blocks[name]
    inc = re.search(r'PORT_INCLUDE\(\s*(\w+)\s*\)', body)
    text = (blocks[inc.group(1)] + "\n" + body) if inc else body
    ports, cur, out = {}, None, []
    curdip = [None]
    def add(port, d):
        # PORT_MODIFY redefines a field in place: keep position, merge the parent's
        # value map underneath so every value of the field still has a label.
        for e in ports[port]:
            if e['mask'] == d['mask']:
                merged = dict(e['vals']); merged.update(d['vals'])
                e['label'] = d['label']; e['def'] = d['def']; e['vals'] = merged
                curdip[0] = e; return
        ports[port].append(d); curdip[0] = d
    for line in text.split('\n'):
        raw = line
        line = re.sub(r'//.*', '', line)
        m = re.search(r'PORT_(?:START|MODIFY)\(\s*"([^"]+)"', line)
        if m: cur = m.group(1); ports.setdefault(cur, []); continue
        if cur is None or not cur.startswith('DIPSW'): 
            m2 = None
        m = re.search(r'PORT_DIPNAME\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*(?:PORT_DIPLOCATION|$)', line)
        if m and cur and cur.startswith('DIPSW'):
            add(cur, {'mask': int(m.group(1), 0), 'def': int(m.group(2), 0),
                      'label': defstr(m.group(3)), 'vals': {}}); continue
        m = re.search(r'PORT_SERVICE_DIPLOC\(\s*(0x[0-9a-fA-F]+)', line)
        if m and cur and cur.startswith('DIPSW'):
            mk = int(m.group(1), 0)
            add(cur, {'mask': mk, 'def': mk, 'label': 'Service Mode',
                      'vals': {0: 'On', mk: 'Off'}}); continue
        m = re.search(r'PORT_DIPUNUSED_DIPLOC\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)', line)
        if m and cur and cur.startswith('DIPSW'):
            mk, dv = int(m.group(1), 0), int(m.group(2), 0)
            add(cur, {'mask': mk, 'def': dv, 'label': 'Unused',
                      'vals': {0: 'On', mk: 'Off'}}); continue
        m = re.search(r'PORT_DIPSETTING\(\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*(?:PORT_CONDITION|$)', line)
        if m and cur and cur.startswith('DIPSW'):
            cond = re.search(r'PORT_CONDITION\([^)]*?,\s*(NOTEQUALS|EQUALS)\s*,', raw)
            # PORT_CONDITION variants: keep the unconditional coinage table (EQUALS 0x00 branch)
            if cond and cond.group(1) == 'NOTEQUALS': continue
            if curdip[0] is not None:
                curdip[0]['vals'][int(m.group(1), 0)] = defstr(m.group(2))
    return ports

# ---------------------------------------------------------------- MRA emission
def emit_region(reg, lo, hi, indent):
    """<part> lines covering region bytes [lo,hi), zero-filling gaps."""
    if reg is None: return [], 0
    segs = sorted([x for x in reg['segs'] if x['dst'] < hi and x['dst'] + x['len'] > lo],
                  key=lambda x: x['dst'])
    lines, pos = [], lo
    for sg in segs:
        a, b = max(sg['dst'], lo), min(sg['dst'] + sg['len'], hi)
        if a > pos:
            lines.append('%s<part repeat="0x%X">00</part>' % (indent, a - pos))
        off = sg['src'] + (a - sg['dst']); ln = b - a
        if off == 0 and ln == sg['len']:
            lines.append('%s<part name="%s" crc="%s"/>' % (indent, sg['file'], sg['crc']))
        else:
            lines.append('%s<part name="%s" crc="%s" offset="0x%X" length="0x%X"/>'
                         % (indent, sg['file'], sg['crc'], off, ln))
        pos = b
    if pos < hi and lines:
        lines.append('%s<part repeat="0x%X">00</part>' % (indent, hi - pos))
        pos = hi
    return lines, pos - lo

SETS = ['ninjakd2','ninjakd2a','ninjakd2b','ninjakd2c','rdaction','jt104',
        'mnight','mnightj','arkarea','robokid','robokidj','robokidj2','robokidj3',
        'omegaf','omegafa','omegafs']
TITLE = {'ninjakd2':'Ninja-Kid II','ninjakd2a':'Ninja-Kid II','ninjakd2b':'Ninja-Kid II',
         'ninjakd2c':'Ninja-Kid II','rdaction':'Rad Action','jt104':'JT 104',
         'mnight':'Mutant Night','mnightj':'Mutant Night','arkarea':'Ark Area',
         'robokid':'Atomic Robo-Kid','robokidj':'Atomic Robo-Kid','robokidj2':'Atomic Robo-Kid',
         'robokidj3':'Atomic Robo-Kid','omegaf':'Omega Fighter','omegafa':'Omega Fighter',
         'omegafs':'Omega Fighter'}
FILENAME = {'ninjakd2':'Ninja-Kid II','ninjakd2a':'Ninja-Kid II (set 2, bootleg)',
            'ninjakd2b':'Ninja-Kid II (set 3, bootleg)','ninjakd2c':'Ninja-Kid II (set 4)',
            'rdaction':'Rad Action','jt104':'JT 104','mnight':'Mutant Night',
            'mnightj':'Mutant Night (Japan)','arkarea':'Ark Area',
            'robokid':'Atomic Robo-Kid','robokidj':'Atomic Robo-Kid (Japan, set 1)',
            'robokidj2':'Atomic Robo-Kid (Japan, set 2)','robokidj3':'Atomic Robo-Kid (Japan)',
            'omegaf':'Omega Fighter','omegafa':'Omega Fighter (set 2)',
            'omegafs':'Omega Fighter Special'}
CATEGORY = {'ninjakd2':'Platform','mnight':'Platform','arkarea':'Shooter',
            'robokid':'Platform','omegaf':'Shooter'}
# region -> (mra index, comment)
REGIDX = [('chars', 2, 'FG char ROM'), ('sprites', 6, 'Sprite ROM'),
          ('tiles1', 7, 'BG tile ROM 1'), ('tiles2', 8, 'BG tile ROM 2'),
          ('tiles3', 9, 'BG tile ROM 3'), ('pcm', 10, 'PCM samples'),
          ('proms', 11, 'PROMs'), ('maincpu_prom', 11, 'Main CPU PROM')]

os.makedirs(OUT, exist_ok=True)
report = []
for i, g in enumerate(SETS):
    md, rg = meta[g], roms[g]
    dp = dips_for(md['ports'])
    vert = (md['rot'] == 'ROT270')
    L = []
    A = L.append
    A('<misterromdescription>')
    A('    <name>%s</name>' % FILENAME[g].replace('&', '&amp;'))
    A('    <setname>%s</setname>' % g)
    A('    <parent>%s</parent>' % (md['parent'] if md['parent'] != '0' else g))
    A('    <year>%s</year>' % md['year'])
    A('    <manufacturer>%s</manufacturer>' % md['mfr'].replace('&', '&amp;'))
    A('    <series>%s</series>' % TITLE[g])
    A('    <category>%s</category>' % CATEGORY.get(md['parent'] if md['parent'] != '0' else g, 'Action'))
    A('    <bootleg>%s</bootleg>' % ('yes' if 'bootleg' in md['full'] else 'no'))
    A('    <mameversion>0270</mameversion>')
    A('    <rbf>UPLFramebuffer</rbf>')
    A('')
    A('    <resolution>15kHz</resolution>')
    A('    <rotation>%s</rotation>' % ('vertical' if vert else 'horizontal'))
    A('    <flip>yes</flip>')
    A('')
    A('    <players>2 (alternating)</players>')
    A('    <joystick>8-way</joystick>')
    A('    <num_buttons>2</num_buttons>')
    A('    <buttons names="Attack,Jump,Not Used,Not Used,Coin,Start 1P,Start 2P,Pause" '
      'default="A,B,Y,X,Select,Start,R,L"/>')
    A('')
    # ---- DIP switches: DIPSW1 -> bits 0..7, DIPSW2 -> bits 8..15
    order = [p for p in ('DIPSW1', 'DIPSW2') if p in dp and dp[p]]
    defbytes = []
    for p in order:
        b = 0xFF
        for d in dp[p]:
            b = (b & ~d['mask']) | (d['def'] & d['mask'])
        defbytes.append(b)
    A('    <switches default="%s">' % ','.join('%02X' % b for b in defbytes))
    for pi, p in enumerate(order):
        for d in dp[p]:
            mk = d['mask']
            lo = (mk & -mk).bit_length() - 1
            hi = mk.bit_length() - 1
            n = hi - lo + 1
            ids = []
            ok = True
            for v in range(1 << n):
                lbl = d['vals'].get(v << lo)
                if lbl is None: ok = False; lbl = '-'
                ids.append(lbl)
            bits = ('%d' % (lo + 8 * pi)) if n == 1 else ('%d,%d' % (lo + 8 * pi, hi + 8 * pi))
            A('        <dip bits="%s" name="%s" ids="%s"/>' % (bits, d['label'], ','.join(ids)))
    A('    </switches>')
    A('')
    zips = 'ninjakd2.zip' if False else None
    par = md['parent'] if md['parent'] != '0' else g
    zipattr = par + '.zip' if par == g else '%s.zip|%s.zip' % (par, g)
    # ---- index 0: main CPU. fixed 0x0000-0x7FFF, then the bank window from 0x10000.
    mc = rg['maincpu']
    A('    <!-- Index 0: Main CPU. 0x0000-0x7FFF fixed, then the 0x4000 banks from region 0x10000 -->')
    A('    <rom index="0" md5="none" zip="%s">' % zipattr)
    l1, n1 = emit_region(mc, 0x0000, 0x8000, '        ')
    l2, n2 = emit_region(mc, 0x10000, mc['size'], '        ')
    L.extend(l1); L.extend(l2)
    A('    </rom>')
    A('')
    sc = rg.get('soundcpu')
    A('    <!-- Index 1: Sound CPU (0x0000-0x17FFF; 0x10000+ is the MC8123 decrypted-opcode half) -->')
    A('    <rom index="1" md5="none" zip="%s">' % zipattr)
    l3, n3 = emit_region(sc, 0x0000, min(sc['size'], 0x18000), '        ')
    L.extend(l3)
    A('    </rom>')
    sizes = {'maincpu': n1 + n2, 'soundcpu': n3}
    for name, idx, cmt in REGIDX:
        r = rg.get(name)
        if not r: continue
        A('')
        A('    <!-- Index %d: %s -->' % (idx, cmt))
        A('    <rom index="%d" md5="none" zip="%s">' % (idx, zipattr))
        ll, nn = emit_region(r, 0, r['size'], '        ')
        L.extend(ll); sizes[name] = nn
        A('    </rom>')
    A('')
    A('    <!-- Index 5: game-select byte -->')
    A('    <!--   %s -->' % '  '.join('%02X %s' % (j, x) for j, x in enumerate(SETS)))
    A('    <rom index="5"><part>%02X</part></rom>' % i)
    A('')
    A('    <remark>%s</remark>' % md['full'].replace('&', '&amp;'))
    A('</misterromdescription>')
    path = os.path.join(OUT, FILENAME[g] + '.mra')
    io.open(path, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
    report.append((g, FILENAME[g], sizes, len(order), sum(len(dp[p]) for p in order), vert))

print("%-11s %-34s %8s %8s %7s %7s %7s %7s %6s %4s" %
      ("set","file","maincpu","sound","chars","spr","tiles","pcm","dips","rot"))
for g, fn, sz, nb, nd, vert in report:
    tiles = sum(sz.get(k, 0) for k in ('tiles1','tiles2','tiles3'))
    print("%-11s %-34s %8d %8d %7d %7d %7d %7d %6d %4s" %
          (g, fn+'.mra', sz.get('maincpu',0), sz.get('soundcpu',0), sz.get('chars',0),
           sz.get('sprites',0), tiles, sz.get('pcm',0), nd, 'V' if vert else 'H'))
