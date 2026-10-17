import React, { useId } from 'react';

/* The decorative lit mushroom. It floats in section corners at 40–80% opacity
   and is never used as an icon — it is scenery. */
export function GlowingMushroom({ size = 'md', style, ...rest }) {
  const sizes = { sm: { width: 50, height: 62 }, md: { width: 70, height: 87 }, lg: { width: 110, height: 137 } };
  const { width, height } = sizes[size];
  const uid = useId().replace(/:/g, '');
  const gid = `kn-glow-${uid}`;
  return (
    <svg style={style} width={width} height={height} viewBox="0 0 60 75" fill="none" {...rest}>
      <defs>
        <filter id={gid} x="-100%" y="-100%" width="300%" height="300%">
          <feGaussianBlur stdDeviation="3" result="coloredBlur"/>
          <feMerge>
            <feMergeNode in="coloredBlur"/>
            <feMergeNode in="SourceGraphic"/>
          </feMerge>
        </filter>
      </defs>
      <path d="M25 45C25 45 23 65 27 70C31 75 33 75 33 70C33 65 30 45 30 45" fill="#5A4A7A"/>
      <ellipse cx="27.5" cy="45" rx="22" ry="15" fill="#7B6B9B"/>
      <ellipse cx="27.5" cy="42" rx="20" ry="13" fill="#8B7BB5"/>
      <circle cx="20" cy="38" r="4" fill="#7DD3C0" filter={`url(#${gid})`}/>
      <circle cx="35" cy="40" r="3" fill="#7DD3C0" filter={`url(#${gid})`}/>
      <circle cx="27" cy="35" r="2.5" fill="#9FEDD7" filter={`url(#${gid})`}/>
      <circle cx="15" cy="44" r="2" fill="#7DD3C0" filter={`url(#${gid})`}/>
      <circle cx="40" cy="43" r="1.5" fill="#9FEDD7" filter={`url(#${gid})`}/>
      <circle cx="18" cy="50" r="4" fill="#FFF8E7" filter={`url(#${gid})`} opacity="0.9"/>
      <circle cx="18" cy="50" r="2" fill="#F5C869"/>
    </svg>
  );
}
