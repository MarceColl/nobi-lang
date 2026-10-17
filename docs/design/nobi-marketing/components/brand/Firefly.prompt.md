A twinkling mote of light with a 12px bloom. Scatter randomly over the page ground.

```jsx
<Firefly color="#F5C869" left="18%" top="34%" duration="5s" delay="1.2s" />
```

The source scatters **35** of them across the full page height, each picking randomly
from four hues — mint `#7DD3C0`, amber `#F5C869`, lilac `#B8A5D9` and mint-light
`#9FEDD7` — with durations of 2–6s and delays of 0–5s, so the field never pulses in
unison. Pair them with the starfield: 30 white 1–3px dots at 0.1–0.5 opacity, confined
to the **top half** of the page.
