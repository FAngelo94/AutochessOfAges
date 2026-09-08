#!/usr/bin/env python3
"""Genera l'icona dell'app: aquila legionaria dentro una corona d'alloro.

Il disegno è calcolato, non disegnato a mano: le remiganti puntano su un arco,
le foglie stanno su un ramo, le squame del petto seguono il profilo del corpo.
Scrivere a mano centinaia di coordinate darebbe una figura storta e impossibile
da ritoccare; qui si sposta una costante e si rigenera.

    python tools/make_icon.py

Scrive icon.svg (icona completa, 512) e le due tavole dell'icona adattiva
Android (android/icons/*.svg), che vanno poi rasterizzate con
tools/rasterize_icon.gd perché l'esportatore vuole dei PNG.
"""

import math
import os

# ---------------------------------------------------------------- palette ---
# Stessi toni di ui/style.gd: notte bluastra sotto, oro sopra. La rampa dell'oro
# ha cinque gradini perché una lamina metallica si legge solo se ogni piano ha
# un tono diverso da quello che gli sta accanto.
NIGHT_TOP = "#131C36"
NIGHT_BOT = "#241F33"
GLOW = "#3B3A6B"
HI = "#FFF4D2"
LT = "#FBD97A"
MID = "#EDB13A"
DK = "#B87A1A"
DEEP = "#8A5510"
SHDW = "#5E3A0C"
OUT = "#241606"

SIZE = 512.0
CX, CY = 256.0, 256.0

# ------------------------------------------------------------- geometria ----
# La corona occupa la fascia fra R_STEM-LEAF_IN e R_STEM+LEAF_OUT, quindi
# l'aquila deve stare dentro EAGLE_R o le punte delle ali toccano le foglie.
R_STEM = 196.0
LEAF_OUT = 32.0
LEAF_IN = 22.0
EAGLE_R = 152.0

_gid = [0]
DEFS = []
BODY = []


# ------------------------------------------------------------- vettori ------
def U(deg):
    """Versore dell'angolo in gradi, con 90 = verso l'alto (y cresce in giù)."""
    r = math.radians(deg)
    return (math.cos(r), -math.sin(r))


def PP(v):
    return (-v[1], v[0])


def A(p, v, k=1.0):
    return (p[0] + v[0] * k, p[1] + v[1] * k)


def mix(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def norm(v):
    m = math.hypot(v[0], v[1]) or 1.0
    return (v[0] / m, v[1] / m)


def on_circle(deg, r):
    return (CX + r * math.cos(math.radians(deg)), CY - r * math.sin(math.radians(deg)))


# ------------------------------------------------------------- emissione ----
def grad(p0, p1, stops):
    _gid[0] += 1
    gid = "g%d" % _gid[0]
    body = "".join('<stop offset="%s" stop-color="%s"/>' % (o, c) for o, c in stops)
    DEFS.append(
        '<linearGradient id="%s" gradientUnits="userSpaceOnUse" '
        'x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f">%s</linearGradient>'
        % (gid, p0[0], p0[1], p1[0], p1[1], body)
    )
    return "url(#%s)" % gid


def path(d, fill, stroke=OUT, sw=1.6, sop=0.5, op=None):
    a = '<path d="%s" fill="%s"' % (d, fill)
    if stroke:
        a += (
            ' stroke="%s" stroke-width="%.2f" stroke-opacity="%.2f"'
            ' stroke-linejoin="round" stroke-linecap="round"' % (stroke, sw, sop)
        )
    if op is not None:
        a += ' opacity="%.2f"' % op
    BODY.append(a + "/>")


def line(pts, color, sw, op=0.5):
    d = "M%.1f,%.1f" % pts[0] + "".join(" L%.1f,%.1f" % p for p in pts[1:])
    BODY.append(
        '<path d="%s" fill="none" stroke="%s" stroke-width="%.2f" '
        'stroke-opacity="%.2f" stroke-linecap="round"/>' % (d, color, sw, op)
    )


def C(*pts):
    return "C" + " ".join("%.1f,%.1f" % p for p in pts)


def M(p):
    return "M%.1f,%.1f" % p


# --------------------------------------------------------------- forme ------
def feather(base, ang, length, wl, wt, bend=0.0):
    """Penna: base piatta, fianchi curvi, punta acuta, con una piega laterale."""
    d, n = U(ang), PP(U(ang))
    tip = A(A(base, d, length), n, bend)
    c1 = A(A(base, d, length * 0.14), n, wl * 0.95 + bend * 0.12)
    c2 = A(A(base, d, length * 0.62), n, wl * 0.88 + bend * 0.62)
    c3 = A(A(base, d, length * 0.62), n, -wt * 0.88 + bend * 0.62)
    c4 = A(A(base, d, length * 0.14), n, -wt * 0.95 + bend * 0.12)
    b0, b1 = A(base, n, wl * 0.22), A(base, n, -wt * 0.22)
    return M(b0) + C(c1, c2, tip) + C(c3, c4, b1) + "Z", tip


def covert_d(base, ang, length, w):
    """Copritrice: come la penna ma con la punta arrotondata, tipo scaglia."""
    d, n = U(ang), PP(U(ang))
    tip = A(base, d, length)
    c1 = A(A(base, d, length * 0.04), n, w)
    c2 = A(A(base, d, length * 1.03), n, w * 0.74)
    c3 = A(A(base, d, length * 1.03), n, -w * 0.74)
    c4 = A(A(base, d, length * 0.04), n, -w)
    b0, b1 = A(base, n, w * 0.6), A(base, n, -w * 0.6)
    return M(b0) + C(c1, c2, tip) + C(c3, c4, b1) + "Z"


def plume(base, ang, length, wl, wt, bend=0.0, light=LT, dark=DEEP, sw=1.6, rachis=True):
    """Penna piena: sfumatura di traverso (bordo d'attacco chiaro) + rachide."""
    d, n = U(ang), PP(U(ang))
    mid = A(A(base, d, length * 0.5), n, bend * 0.5)
    g = grad(A(mid, n, wl), A(mid, n, -wt), [("0", light), ("0.55", dark), ("1", SHDW)])
    dd, tip = feather(base, ang, length, wl, wt, bend)
    path(dd, g, sw=sw)
    if rachis:
        line([base, mix(base, tip, 0.45), mix(base, tip, 0.88)], SHDW,
             max(1.0, wl * 0.16), 0.4)


def plume_to(base, tip, wl, wt, bend=0.0, **kw):
    """Come plume(), ma la penna la si punta: base e punta, non angolo e lunghezza.
    È così che si riempie un tondo — le punte stanno tutte sullo stesso arco."""
    dx, dy = tip[0] - base[0], tip[1] - base[1]
    plume(base, math.degrees(math.atan2(-dy, dx)), math.hypot(dx, dy), wl, wt, bend, **kw)


def scale_shape(base, ang, length, w, light, dark, sw=1.4, sop=0.42):
    d, n = U(ang), PP(U(ang))
    mid = A(base, d, length * 0.5)
    path(covert_d(base, ang, length, w),
         grad(A(mid, n, w), A(mid, n, -w), [("0", light), ("0.6", dark), ("1", DEEP)]),
         sw=sw, sop=sop)


# ------------------------------------------------------------- sfondo -------
def build_background(rounded=True):
    DEFS.append(
        '<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/>'
        "</linearGradient>" % (NIGHT_TOP, NIGHT_BOT)
    )
    DEFS.append(
        '<radialGradient id="glow" cx="0.5" cy="0.46" r="0.52">'
        '<stop offset="0" stop-color="%s" stop-opacity="0.55"/>'
        '<stop offset="1" stop-color="%s" stop-opacity="0"/>'
        "</radialGradient>" % (GLOW, GLOW)
    )
    if rounded:
        BODY.append('<rect width="512" height="512" rx="112" fill="url(#sky)"/>')
    else:
        BODY.append('<rect width="512" height="512" fill="url(#sky)"/>')
    BODY.append('<rect width="512" height="512" rx="112" fill="url(#glow)"/>')


# -------------------------------------------------------------- corona ------
def build_wreath():
    """Due rami speculari: partono dal nodo in basso e salgono fino quasi a
    toccarsi in cima. Il varco in alto e il nastro in basso sono ciò che
    distingue una corona vera da una ghirlanda di foglie messe in cerchio."""
    def pos(phi, r=R_STEM):
        a = math.radians(phi)
        return (CX + r * math.sin(a), CY - r * math.cos(a))

    for side in (-1, 1):
        p0, p2 = pos(10 * side), pos(172 * side)
        BODY.append(
            '<path d="M%.1f,%.1f A%.1f,%.1f 0 0 %d %.1f,%.1f" fill="none" '
            'stroke="%s" stroke-width="5" stroke-linecap="round"/>'
            % (p0[0], p0[1], R_STEM, R_STEM, 1 if side > 0 else 0, p2[0], p2[1], DEEP)
        )

        steps = 17
        for i in range(steps):
            t = i / float(steps - 1)
            phi = (14 + t * 154) * side
            a = math.radians(phi)
            radial = (math.sin(a), -math.cos(a))
            growth = (-math.cos(a) * side, -math.sin(a) * side)
            # Le foglie in punta al ramo sono più piccole: t=0 è la cima.
            taper = 0.62 + 0.38 * min(1.0, t * 2.2)
            base = pos(phi)
            for outward, length, tilt in ((1, LEAF_OUT * taper, 0.62),
                                          (-1, LEAF_IN * taper, 0.72)):
                v = (radial[0] * outward * math.cos(tilt) + growth[0] * math.sin(tilt),
                     radial[1] * outward * math.cos(tilt) + growth[1] * math.sin(tilt))
                ang = math.degrees(math.atan2(-v[1], v[0]))
                b = A(base, v, 2.0)
                w = length * 0.30
                d, n = U(ang), PP(U(ang))
                mid = A(b, d, length * 0.5)
                tone = LT if (i % 2 == 0) else MID
                g = grad(A(mid, n, w), A(mid, n, -w),
                         [("0", tone), ("0.6", DK), ("1", DEEP)])
                dd, tip = feather(b, ang, length, w, w, 0.0)
                path(dd, g, sw=1.5, sop=0.55)
                line([b, mix(b, tip, 0.85)], SHDW, 1.1, 0.4)

    # Nodo e nastro in basso.
    knot = (CX, CY + R_STEM)
    for s in (-1, 1):
        d = (M((CX + s * 6, knot[1] + 2))
             + C((CX + s * 34, knot[1] + 10), (CX + s * 46, knot[1] + 26),
                 (CX + s * 70, knot[1] + 22))
             + C((CX + s * 54, knot[1] + 34), (CX + s * 40, knot[1] + 26),
                 (CX + s * 10, knot[1] + 14))
             + "Z")
        path(d, grad((CX, knot[1]), (CX, knot[1] + 34), [("0", MID), ("1", DEEP)]), sw=1.3)
    path(M((CX - 15, knot[1] - 9))
         + C((CX + 15, knot[1] - 15), (CX + 15, knot[1] + 9), (CX - 15, knot[1] + 8))
         + C((CX - 22, knot[1] + 4), (CX - 22, knot[1] - 4), (CX - 15, knot[1] - 9))
         + "Z",
         grad((CX, knot[1] - 10), (CX, knot[1] + 10),
              [("0", HI), ("0.5", MID), ("1", DEEP)]), sw=1.5)


# --------------------------------------------------------------- aquila -----
# Proporzioni da rapace, non da pulcino: l'apertura alare è il doppio
# dell'altezza del corpo, e il corpo è stretto. Un corpo largo si mangia le ali
# e la figura torna a sembrare un uccellino visto di fronte.
WING_C = (CX, 248.0)          # centro delle fasce dell'ala: la spalla
WING_R = 150.0                # raggio delle punte delle primarie
BODY_TOP, BODY_BOT = 176.0, 306.0
BODY_HW = 33.0                # semilarghezza massima del petto
TAIL_ROOT = (CX, 300.0)
PERCH_Y = 352.0


def mir(p, side):
    return p if side < 0 else (2 * CX - p[0], p[1])


def half_width(y):
    t = (y - BODY_TOP) / (BODY_BOT - BODY_TOP)
    t = min(1.0, max(0.0, t))
    return 24.0 + (BODY_HW - 24.0) * math.sin(math.pi * t ** 0.85)


# Profilo del bordo esterno dell'ala, per angolo: il massimo sta verso l'esterno
# (165°), non sulla diagonale. Con il picco in diagonale l'apertura alare
# orizzontale si dimezza e la figura sembra uno scarabeo con le ali chiuse.
WING_PROFILE = ((104, 0.54), (125, 0.78), (145, 0.93), (165, 1.00),
                (182, 0.97), (196, 0.82), (210, 0.62))


def wing_r(a):
    if a <= WING_PROFILE[0][0]:
        return WING_R * WING_PROFILE[0][1]
    for (a0, k0), (a1, k1) in zip(WING_PROFILE, WING_PROFILE[1:]):
        if a <= a1:
            return WING_R * (k0 + (k1 - k0) * (a - a0) / (a1 - a0))
    return WING_R * WING_PROFILE[-1][1]


def wing(side):
    """side=-1 ala sinistra, +1 destra (specchiata).

    L'ala è fatta di fasce concentriche attorno alla spalla: copritrici corte
    sotto, remiganti lunghe sopra, tutte lunghe in proporzione al bordo esterno.
    Farle partire tutte da un punto dà una felce, farle seguire l'avambraccio dà
    un sigaro: provate entrambe, le fasce sono l'unica costruzione che regge."""
    def polar(deg, r):
        a = math.radians(deg if side < 0 else 180.0 - deg)
        return (WING_C[0] + r * math.cos(a), WING_C[1] - r * math.sin(a))

    def aim(base, tip):
        dx, dy = tip[0] - base[0], tip[1] - base[1]
        return math.degrees(math.atan2(-dy, dx)), math.hypot(dx, dy)

    # Copritrici: tre fasce che escono da dietro il corpo, la massa piena su cui
    # si innestano le remiganti.
    for n, kb, kl, kw, light, dark in ((12, 0.30, 0.27, 0.092, LT, DK),
                                       (10, 0.16, 0.20, 0.086, HI, MID),
                                       (8, 0.05, 0.14, 0.080, HI, LT)):
        for i in range(n):
            a = 106.0 + (i / float(n - 1)) * 104.0
            r = wing_r(a)
            base = polar(a, kb * r)
            ang, ln = aim(base, polar(a - 12, (kb + kl) * r))
            scale_shape(base, ang, ln, kw * r, light, dark, sw=1.5, sop=0.5)

    # Remiganti: una sola fila continua dalla punta dell'ala fino al corpo.
    # Larghe apposta: se la larghezza è minore del passo fra una punta e l'altra
    # le penne non si sovrappongono e l'ala torna a sembrare una felce.
    for i in range(13):
        t = i / 12.0
        a = 108.0 + t * 102.0
        r = wing_r(a)
        plume_to(polar(a + 15, 0.52 * r), polar(a, r),
                 0.115 * r, 0.088 * r, -side * (9 - 5 * t),
                 light=HI if i % 2 else LT, dark=DK if i % 2 else DEEP)


def build_eagle():
    for side in (-1, 1):
        wing(side)

    # Coda: deve sbucare sotto il posatoio, se resta sopra la figura sembra
    # tagliata a metà e l'uccello appoggiato su un tubo.
    for i in range(5):
        t = i / 4.0
        a = 250 + t * 40
        plume(A(TAIL_ROOT, U(a), 6), a, 94 - abs(t - 0.5) * 18, 14.0, 12.0,
              light=LT if i % 2 else MID, dark=SHDW)

    # Fulmine di Giove come posatoio: due fusi sfaccettati e una fascetta.
    # Da lontano è solo la barra che regge la figura, da vicino è imperiale.
    for s in (-1, 1):
        pts = [(10, -4), (38, -11), (56, -7), (86, 0), (56, 7), (38, 11), (10, 4)]
        d = M((CX + s * pts[0][0], PERCH_Y + pts[0][1]))
        for dx, dy in pts[1:]:
            d += " L%.1f,%.1f" % (CX + s * dx, PERCH_Y + dy)
        path(d + "Z",
             grad((CX, PERCH_Y - 11), (CX, PERCH_Y + 11),
                  [("0", LT), ("0.5", DK), ("1", SHDW)]))
    # Fascetta: stretta e scura. Larga e chiara sembrava un'etichetta incollata.
    path(M((CX - 9, PERCH_Y - 12)) + " L%.1f,%.1f" % (CX + 9, PERCH_Y - 12)
         + " L%.1f,%.1f" % (CX + 9, PERCH_Y + 12)
         + " L%.1f,%.1f" % (CX - 9, PERCH_Y + 12) + "Z",
         grad((CX - 9, PERCH_Y), (CX + 9, PERCH_Y),
              [("0", DEEP), ("0.45", MID), ("1", SHDW)]), sw=1.4)

    # Zampe: coscia piumata corta, tarso squamato, tre dita con artiglio.
    for s in (-1, 1):
        hx = CX + s * 27
        scale_shape((hx, 284.0), 268 + s * 4, 34, 16, LT, DK, sw=1.5, sop=0.5)
        path(M((hx - 8, 312)) + C((hx - 7, 324), (hx - 7, 332), (hx - 8, 342))
             + " L%.1f,%.1f" % (hx + 8, 342)
             + C((hx + 7, 332), (hx + 7, 324), (hx + 8, 312)) + "Z",
             grad((hx - 8, 326), (hx + 8, 326), [("0", MID), ("0.5", LT), ("1", DEEP)]),
             sw=1.4)
        for k in range(3):
            tx = hx + (k - 1) * 12
            out = 1 if k else -1
            path(M((tx - 7, 338))
                 + C((tx - 8, 352), (tx - 6, 364), (tx + 9 * out, 376))
                 + C((tx + 2, 362), (tx + 7, 350), (tx + 7, 338)) + "Z",
                 grad((tx, 336), (tx, 376), [("0", HI), ("0.5", MID), ("1", SHDW)]),
                 sw=1.5, sop=0.65)

    # Corpo: collo stretto, petto pieno, ventre che si richiude. Con i fianchi
    # paralleli veniva un lingotto squadrato con la testa appoggiata sopra.
    path(M((CX - 13, BODY_TOP))
         + C((CX - 32, 198), (CX - BODY_HW - 3, 244), (CX - 26, 292))
         + C((CX - 20, 316), (CX + 20, 316), (CX + 26, 292))
         + C((CX + BODY_HW + 3, 244), (CX + 32, 198), (CX + 13, BODY_TOP))
         + "Z",
         grad((CX - 38, 196), (CX + 38, 300), [("0", LT), ("0.45", MID), ("1", DEEP)]),
         sw=1.8, sop=0.55)

    # Petto: archetti stretti e sfalsati fra una riga e l'altra. Allineati in
    # colonna sembravano onde d'acqua, non piume.
    for r, y in enumerate((214.0, 232.0, 250.0, 268.0)):
        hw = half_width(y) * 0.60
        n = 3 + r
        for i in range(n):
            x = CX - hw + (2 * hw) * (i / float(n - 1))
            w = hw / n * 1.25
            if r % 2:
                x += w
            BODY.append('<path d="M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f" fill="none" '
                        'stroke="%s" stroke-width="2.0" stroke-opacity="0.28" '
                        'stroke-linecap="round"/>'
                        % (x - w, y, x, y + w * 1.15, x + w, y, SHDW))

    # Collare: le penne stanno su un anello attorno alla base del collo. Con le
    # basi tutte nello stesso punto veniva una rosetta appiccicata sul petto.
    for i in range(9):
        a = 202 + (i / 8.0) * 136
        plume(A((CX, 178.0), U(a), 21), a, 20, 7.0, 6.0,
              light=HI, dark=DK, sw=1.3, rachis=False)

    build_head()


HEAD_AT = (256.0, 150.0)      # dove finisce l'occhio, non il centro della testa
HEAD_S = 1.22


def build_head():
    """Testa di profilo su corpo frontale: è la posa delle insegne romane, e di
    faccia il becco uncinato — l'unico dettaglio che rende un'aquila un'aquila —
    sparirebbe del tutto.

    Disegnata attorno all'origine e poi piazzata con una trasformazione: in
    coordinate assolute ogni ritocco di scala voleva venti numeri riscritti a
    mano, ed è così che la testa era diventata da dodo."""
    mark = len(BODY)

    # Cranio: fronte piatta che scende dritta nel becco. La calotta tonda è la
    # differenza fra un rapace e un pulcino.
    path(M((-11.0, -13.0)) + C((-5.0, -22.0), (12.0, -21.0), (17.0, -10.0))
         + C((21.0, -1.0), (20.0, 10.0), (14.0, 17.0))
         + C((7.0, 22.0), (-4.0, 20.0), (-9.0, 13.0))
         + C((-12.0, 6.0), (-14.0, -5.0), (-11.0, -13.0)) + "Z",
         grad((-11.0, -22.0), (18.0, 19.0), [("0", HI), ("0.5", LT), ("1", DK)]),
         sw=1.4)

    # Ciuffi della nuca: senza, la testa resta una pallina liscia.
    for i in range(3):
        a = 318 + i * 26
        plume(A((15.0, 6.0), U(a), 1), a, 16 - i * 2, 5.0, 4.2,
              light=LT, dark=DEEP, sw=1.0, rachis=False)

    # Sopracciglio sporgente: è questo che dà lo sguardo, non l'occhio.
    path(M((-10.0, -7.0)) + C((-3.0, -15.0), (7.0, -15.0), (13.0, -9.0))
         + C((6.0, -11.0), (-2.0, -9.0), (-6.0, -2.0)) + "Z", SHDW, stroke=None)

    # Occhio piccolo, schiacciato sotto il sopracciglio.
    BODY.append('<ellipse cx="0" cy="0" rx="5.2" ry="4.4" fill="%s" stroke="%s" '
                'stroke-width="1.2" stroke-opacity="0.6"/>' % (LT, OUT))
    BODY.append('<circle cx="-0.8" cy="0.4" r="2.6" fill="%s"/>' % OUT)
    BODY.append('<circle cx="-1.8" cy="-0.8" r="1.0" fill="%s"/>' % HI)

    # Cera, poi il becco: corto e alto all'attacco, uncino netto. Lungo e
    # sottile faceva anatra.
    path(M((-9.0, -12.0)) + C((-16.0, -11.0), (-19.0, -6.0), (-18.0, -1.0))
         + C((-13.0, -1.0), (-9.0, -5.0), (-8.0, -9.0)) + "Z", DK, sw=1.0)
    path(M((-8.0, -12.0))
         + C((-21.0, -9.0), (-31.0, -1.0), (-34.0, 8.0))
         + C((-36.0, 15.0), (-29.0, 18.5), (-28.0, 12.0))
         + C((-25.0, 5.0), (-17.0, 1.0), (-9.0, 0.0))
         + C((-4.0, -0.5), (-3.0, -7.0), (-6.0, -10.5)) + "Z",
         grad((-32.0, -7.0), (-7.0, 15.0), [("0", HI), ("0.45", MID), ("1", DEEP)]),
         sw=1.3)
    path(M((-10.0, 1.0)) + C((-19.0, 4.5), (-15.0, 9.5), (-8.0, 9.5))
         + C((-3.0, 9.5), (-2.0, 4.5), (-4.5, 1.0)) + "Z", DEEP, sw=1.0)
    line([(-27.0, 6.0), (-13.0, 1.0), (-4.5, -2.5)], SHDW, 1.2, 0.55)

    inner = "".join(BODY[mark:])
    del BODY[mark:]
    BODY.append('<g transform="translate(%.1f %.1f) scale(%.2f)">%s</g>'
                % (HEAD_AT[0], HEAD_AT[1], HEAD_S, inner))


# ---------------------------------------------------------------- output ----
def render(rounded=True, wreath=True, eagle=True, background=True, scale=1.0):
    DEFS.clear()
    BODY.clear()
    _gid[0] = 0
    if background:
        build_background(rounded)
    mark = len(BODY)
    if wreath:
        build_wreath()
    if eagle:
        build_eagle()
    inner = BODY[mark:]
    del BODY[mark:]
    art = "\n  ".join(inner)
    if scale != 1.0:
        art = '<g transform="translate(%.2f %.2f) scale(%.4f)">\n  %s\n  </g>' % (
            CX * (1 - scale), CY * (1 - scale), scale, art)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" '
            'viewBox="0 0 512 512">\n'
            "  <!-- GENERATO DA tools/make_icon.py - non modificare a mano. -->\n"
            "  <defs>\n    %s\n  </defs>\n  %s\n  %s\n</svg>\n"
            % ("\n    ".join(DEFS), "\n  ".join(BODY), art))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "icon.svg")
    with open(out, "w", encoding="utf-8") as f:
        f.write(render())
    print("scritto", out)

    icons = os.path.join(root, "android", "icons")
    os.makedirs(icons, exist_ok=True)
    # Icona adattiva Android: il primo piano viene ritagliato in cerchio, quindi
    # l'emblema va rimpicciolito dentro la zona sicura (66% della tavola).
    with open(os.path.join(icons, "foreground.svg"), "w", encoding="utf-8") as f:
        f.write(render(background=False, scale=0.64))
    with open(os.path.join(icons, "background.svg"), "w", encoding="utf-8") as f:
        f.write(render(rounded=False, wreath=False, eagle=False))
    print("scritto", icons)


if __name__ == "__main__":
    main()
