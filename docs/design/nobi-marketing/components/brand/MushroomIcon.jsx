import React from 'react';

/* The five feature glyphs, lifted verbatim from landing/src/App.tsx.
   Every path takes its color from the `color` prop; fills are the same hue at
   hex-alpha 30/40, which is why color must be a literal hex string. */
export function MushroomIcon({ variant = 'sprout', color = '#7DD3C0', size = 40, ...rest }) {
  const icons = {
    sprout: (
      <svg width={size} height={size} viewBox="0 0 32 32" fill="none" {...rest}>
        <path d="M16 28V18" stroke={color} strokeWidth="2" strokeLinecap="round"/>
        <path d="M16 18C16 18 10 18 10 13C10 8 16 6 16 6C16 6 22 8 22 13C22 18 16 18 16 18Z" fill={`${color}30`} stroke={color} strokeWidth="1.5"/>
        <circle cx="13" cy="12" r="1.5" fill={color}/>
        <circle cx="18" cy="10" r="1" fill={color}/>
        <path d="M12 26C12 26 14 24 16 24C18 24 20 26 20 26" stroke={color} strokeWidth="1.5" strokeLinecap="round"/>
      </svg>
    ),
    glow: (
      <svg width={size} height={size} viewBox="0 0 32 32" fill="none" {...rest}>
        <circle cx="16" cy="14" r="8" fill={`${color}15`}/>
        <path d="M16 28V20" stroke={color} strokeWidth="2" strokeLinecap="round"/>
        <ellipse cx="16" cy="20" rx="8" ry="4" fill={`${color}30`} stroke={color} strokeWidth="1.5"/>
        <circle cx="12" cy="18" r="2" fill={color} opacity="0.8"/>
        <circle cx="19" cy="17" r="1.5" fill={color} opacity="0.8"/>
        <circle cx="15" cy="15" r="1" fill={color} opacity="0.6"/>
      </svg>
    ),
    spore: (
      <svg width={size} height={size} viewBox="0 0 32 32" fill="none" {...rest}>
        <path d="M16 26V20" stroke={color} strokeWidth="2" strokeLinecap="round"/>
        <ellipse cx="16" cy="20" rx="6" ry="3" fill={`${color}30`} stroke={color} strokeWidth="1.5"/>
        <circle cx="8" cy="10" r="2" fill={color} opacity="0.6"/>
        <circle cx="16" cy="6" r="2.5" fill={color} opacity="0.8"/>
        <circle cx="24" cy="12" r="2" fill={color} opacity="0.6"/>
        <circle cx="12" cy="14" r="1.5" fill={color} opacity="0.4"/>
        <circle cx="22" cy="8" r="1.5" fill={color} opacity="0.5"/>
        <circle cx="20" cy="16" r="1" fill={color} opacity="0.4"/>
      </svg>
    ),
    cluster: (
      <svg width={size} height={size} viewBox="0 0 32 32" fill="none" {...rest}>
        <path d="M10 28V24" stroke={color} strokeWidth="1.5" strokeLinecap="round"/>
        <ellipse cx="10" cy="24" rx="5" ry="3" fill={`${color}30`} stroke={color} strokeWidth="1.5"/>
        <circle cx="8" cy="22" r="1.5" fill={color}/>
        <path d="M20 28V22" stroke={color} strokeWidth="1.5" strokeLinecap="round"/>
        <ellipse cx="20" cy="22" rx="6" ry="3.5" fill={`${color}30`} stroke={color} strokeWidth="1.5"/>
        <circle cx="18" cy="20" r="1.5" fill={color}/>
        <circle cx="22" cy="19" r="1" fill={color}/>
        <path d="M15 26V23" stroke={color} strokeWidth="1.5" strokeLinecap="round"/>
        <ellipse cx="15" cy="23" rx="4" ry="2.5" fill={`${color}30`} stroke={color} strokeWidth="1.5"/>
      </svg>
    ),
    cap: (
      <svg width={size} height={size} viewBox="0 0 32 32" fill="none" {...rest}>
        <path d="M16 28V18" stroke={color} strokeWidth="2" strokeLinecap="round"/>
        <path d="M6 18C6 18 6 8 16 8C26 8 26 18 26 18" fill={`${color}30`}/>
        <path d="M6 18C6 18 6 8 16 8C26 8 26 18 26 18" stroke={color} strokeWidth="1.5" strokeLinecap="round"/>
        <ellipse cx="16" cy="18" rx="10" ry="3" fill={`${color}40`} stroke={color} strokeWidth="1.5"/>
        <circle cx="11" cy="13" r="2" fill={color} opacity="0.7"/>
        <circle cx="18" cy="11" r="1.5" fill={color} opacity="0.7"/>
        <circle cx="21" cy="15" r="1" fill={color} opacity="0.5"/>
      </svg>
    ),
  };
  return icons[variant];
}
