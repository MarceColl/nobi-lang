The site's repeating content unit: a mushroom glyph, a Fraunces title, a muted line of copy.

```jsx
<FeatureCard variant="sprout" hue="#7DD3C0" title="Strong type system"
  description="Catch errors at definition time, not runtime." />
```

Full size (three-up) gets the 56px haloed icon tile; `compact` (four-up infrastructure grid) drops the halo. `comingSoon` adds the amber badge and dims the card. `hue` must be a literal hex — it's interpolated into rgba suffixes.
