import React from 'react';

/* Kinoko's actions are pills. The primary is the violet-to-mint gradient with a
   mint bloom under it; the nav variant swaps the second stop for the deeper teal. */
export function Button({ variant = 'primary', size = 'md', square = false, block = false, disabled = false, children, style, ...rest }) {
  const pads = { sm: '8px 16px', md: '10px 20px', lg: '16px 32px' };
  const sizes = { sm: 'var(--text-xs)', md: 'var(--text-ui)', lg: 'var(--text-section-lead)' };

  const variants = {
    primary: {
      background: 'var(--grad-primary)',
      color: '#fff',
      border: 'none',
      boxShadow: size === 'lg' ? 'var(--glow-mint)' : 'none',
    },
    nav: {
      background: 'var(--grad-nav)',
      color: '#fff',
      border: '1px solid var(--kn-border-violet-strong)',
    },
    ghost: {
      background: 'transparent',
      color: 'var(--kn-text-muted)',
      border: '1px solid var(--kn-border-violet-strong)',
    },
    quiet: {
      background: 'none',
      color: 'var(--kn-text-dim)',
      border: 'none',
    },
  };

  return (
    <button
      disabled={disabled}
      style={{
        padding: pads[size],
        fontSize: sizes[size],
        fontFamily: 'var(--font-body)',
        fontWeight: size === 'lg' ? 'var(--weight-semibold)' : 'var(--weight-regular)',
        borderRadius: square ? 'var(--radius-lg)' : 'var(--radius-pill)',
        width: block ? '100%' : undefined,
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.45 : 1,
        lineHeight: 1.2,
        transition: 'filter var(--dur-fast) var(--ease), transform var(--dur-fast) var(--ease)',
        ...variants[variant],
        ...style,
      }}
      onMouseEnter={(e) => !disabled && (e.currentTarget.style.filter = 'brightness(1.12)')}
      onMouseLeave={(e) => { e.currentTarget.style.filter = 'none'; e.currentTarget.style.transform = 'none'; }}
      onMouseDown={(e) => !disabled && (e.currentTarget.style.transform = 'scale(0.97)')}
      onMouseUp={(e) => (e.currentTarget.style.transform = 'none')}
      {...rest}
    >
      {children}
    </button>
  );
}
