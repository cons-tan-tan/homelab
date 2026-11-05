#set document(title: "Home WAN/LAN Wiring")
#set page(width: 1184pt, height: 900pt, margin: 32pt, fill: white)
#set text(font: "Noto Sans CJK JP", lang: "en", size: 10pt, fill: rgb("243747"))
#set par(leading: 3pt)

#let ink = rgb("243747")
#let muted = rgb("536574")
#let networks = (
  wan: (id: 10, color: rgb("B45B22"), fill: rgb("FFF0E3")),
  lan: (id: 20, color: rgb("24776B"), fill: rgb("E6F3EE")),
  trunk: (color: rgb("7862A6"), fill: rgb("F0EAF8")),
  management: (id: 1, color: rgb("677384"), fill: rgb("EEF1F4")),
)

// Port order determines both the rows and the connection anchors.
#let ports-a = (
  (label: [ONU], network: "wan"),
  (label: [Trunk (to living room)], network: "trunk"),
  (label: [Room 1], network: "lan"),
  (label: [Room 2], network: "lan"),
  (label: [Room 3], network: "lan"),
  (label: [Room 4], network: "lan"),
  (label: [Room 5 / spare], network: "lan"),
  (label: [Management / reserved (unused)], network: "management"),
)
#let ports-b = (
  (label: [Trunk (from bathroom)], network: "trunk"),
  (label: [Router WAN], network: "wan"),
  (label: [Router LAN], network: "lan"),
  (label: [Spare / local device], network: "lan"),
  (label: [Management / reserved (unused)], network: "management"),
)

// Coordinates and dimensions are in points, relative to the diagram.
#let switch-width = 340
#let switch-header = 40
#let port-height = 34
#let swa = (240, 40)
#let swb = (300, 476)
#let at(x, y, body) = place(top + left, dx: x * 1pt, dy: y * 1pt, body)
#let port-anchor(origin, port, side: "right") = (
  origin.at(0) + if side == "right" { switch-width } else { 0 },
  origin.at(1) + switch-header + (port - 0.5) * port-height,
)

#let area(x, y, width, height, title, fill, border) = at(x, y, block(
  width: width * 1pt,
  height: height * 1pt,
  fill: fill,
  stroke: (paint: border, thickness: 0.8pt, dash: "dashed"),
  radius: 10pt,
  inset: 14pt,
  text(13pt, weight: "bold", title),
))

#let device(x, y, width, height, body, network: "management") = {
  let style = networks.at(network)
  at(x, y, block(
    width: width * 1pt,
    height: height * 1pt,
    fill: style.fill,
    stroke: 0.8pt + style.color,
    radius: 5pt,
    inset: 6pt,
    align(center + horizon, body),
  ))
}

#let wire(points, network, dashed: false) = {
  let (start, ..rest) = points.map(point => point.map(value => value * 1pt))
  at(0, 0, curve(
    curve.move(start),
    ..rest.map(curve.line),
    stroke: (
      paint: networks.at(network).color,
      thickness: if network == "trunk" { 2.8pt } else { 1.8pt },
      dash: if dashed { "dashed" } else { "solid" },
      cap: "round",
      join: "round",
    ),
  ))
}

#let switch(origin, title, ports) = {
  let (x, y) = origin
  at(x, y, block(
    width: switch-width * 1pt,
    height: switch-header * 1pt,
    fill: ink,
    radius: (top: 5pt),
    inset: 10pt,
    text(12pt, fill: white, weight: "bold", title),
  ))
  for (index, port) in ports.enumerate() {
    let style = networks.at(port.network)
    let vlan = if port.network == "trunk" {
      [Tagged VLAN 10 + 20 / Untagged VLAN 1 / PVID=1]
    } else {
      [Untagged VLAN #style.id / PVID=#style.id]
    }
    at(x, y + switch-header + index * port-height, block(
      width: switch-width * 1pt,
      height: port-height * 1pt,
      fill: style.fill,
      stroke: 0.5pt + white,
      inset: (x: 10pt, y: 5pt),
      grid(
        columns: (25pt, 1fr),
        column-gutter: 7pt,
        align: left + horizon,
        text(11pt, weight: "bold", fill: style.color)[P#(index + 1)],
        [
          #text(10pt, weight: "medium", port.label) \
          #text(8.5pt, fill: muted, vlan)
        ],
      ),
    ))
  }
}

#let legend-item(network, title, description) = {
  let style = networks.at(network)
  grid(
    columns: (8pt, 1fr),
    column-gutter: 8pt,
    rect(width: 8pt, height: 27pt, fill: style.color, stroke: none, radius: 2pt),
    [#text(10pt, weight: "bold", title) \ #text(8.5pt, fill: muted, description)],
  )
}

#block(width: 1120pt, height: 836pt)[
  #at(0, 0, text(24pt, weight: "bold")[Home WAN/LAN Wiring])
  #at(0, 39, text(11pt, fill: muted)[VLAN design / Port assignments and in-wall cabling])

  #at(0, 76, block(width: 1120pt, height: 746pt)[
    #area(0, 0, 610, 376, [Above bathroom ceiling], rgb("F4F8FC"), rgb("9DB6CC"))
    #area(744, 0, 376, 236, [Room 1 (example)], rgb("FCF6F0"), rgb("C8AB8D"))
    #area(0, 430, 1120, 312, [Living room], rgb("FAF8F2"), rgb("C8BC94"))

    #at(800, 514, block(
      width: 264pt,
      height: 114pt,
      fill: white,
      stroke: 0.8pt + rgb("A9B5BF"),
      radius: 6pt,
      inset: 12pt,
      text(12pt, weight: "bold")[Wi-Fi router],
    ))

    // Draw cables before equipment so lines meet the port edges cleanly.
    #wire(((149, 97), port-anchor(swa, 1, side: "left")), "wan")
    #wire((port-anchor(swa, 2, side: "left"), (195, 131), (195, 460)), "trunk")
    #wire(((195, 504), (195, 533), port-anchor(swb, 1, side: "left")), "trunk")
    #wire((port-anchor(swa, 3), (888, 165)), "lan")
    #wire(((888, 165), (932, 165)), "lan", dashed: true)
    #wire((port-anchor(swb, 2), (818, 567)), "wan")
    #wire((port-anchor(swb, 3), (818, 601)), "lan")
    #wire((port-anchor(swb, 4), (725, 635), (725, 697), (800, 697)), "lan", dashed: true)

    #switch(swa, [SW-A: NETGEAR GS308E (8 ports)], ports-a)
    #device(24, 70, 125, 54, [*ONU* \ #text(9pt)[Optical network unit]], network: "wan")
    #at(157, 78, text(8.5pt, fill: networks.wan.color)[VLAN 10])

    #device(640, 151, 74, 28, [In-wall wiring])
    #device(768, 151, 120, 28, [Room 1 wall port], network: "lan")
    #device(932, 137, 164, 56, [*Room 1 PC / TV, etc.* \ VLAN 20], network: "lan")

    #at(744, 256, block(
      width: 376pt,
      height: 120pt,
      stroke: 0.8pt + rgb("D7DEE4"),
      radius: 8pt,
      inset: 14pt,
    )[
      #text(11pt, weight: "bold")[Legend]
      #v(9pt)
      #grid(
        columns: (1fr, 1fr),
        column-gutter: 14pt,
        row-gutter: 10pt,
        legend-item("wan", [VLAN 10], [WAN / Internet]),
        legend-item("lan", [VLAN 20], [LAN / Home network]),
        legend-item("trunk", [Trunk], [Tagged VLAN 10 + 20]),
        legend-item("management", [VLAN 1], [Management]),
      )
    ])

    #device(140, 389, 110, 28, [In-wall wiring], network: "trunk")
    #device(140, 460, 110, 44, [*Living room* \ Wall port], network: "trunk")
    #switch(swb, [SW-B: NETGEAR GS305E (5 ports)], ports-b)

    #device(818, 554, 228, 26, [*WAN*], network: "wan")
    #device(818, 588, 228, 26, [*LAN*], network: "lan")
    #at(660, 549, text(9pt, fill: networks.wan.color)[VLAN 10 / Untagged])
    #at(660, 583, text(9pt, fill: networks.lan.color)[VLAN 20 / Untagged])
    #device(800, 670, 264, 54, [*Living room PC / TV, etc.* \ VLAN 20], network: "lan")
  ])
]
