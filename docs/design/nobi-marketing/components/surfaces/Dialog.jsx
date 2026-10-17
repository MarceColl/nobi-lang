import React from 'react';

export function Dialog({ open = true, title, description, onClose, children, style, ...rest }) {
  if (!open) return null;
  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 1000,
        background: 'rgba(10, 8, 15, 0.9)',
        backdropFilter: 'blur(8px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 'var(--space-6)',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: 'var(--grad-dialog)',
          border: '1px solid var(--kn-border-violet-strong)',
          borderRadius: 'var(--radius-2xl)',
          padding: 'clamp(32px, 6vw, 48px)',
          maxWidth: 440, width: '100%',
          position: 'relative',
          boxShadow: 'var(--glow-dialog)',
          ...style,
        }}
        {...rest}
      >
        {onClose && (
          <button
            onClick={onClose}
            aria-label="Close"
            style={{
              position: 'absolute', top: 16, right: 16,
              background: 'none', border: 'none', cursor: 'pointer',
              color: 'var(--kn-text-dim)', fontSize: 24, lineHeight: 1, padding: 8,
            }}
          >
            ×
          </button>
        )}
        {title && (
          <h3 style={{ fontFamily: 'var(--font-display)', fontSize: 'var(--text-dialog-title)', fontWeight: 'var(--weight-bold)', color: 'var(--kn-text)', marginBottom: 'var(--space-3)', textAlign: 'center' }}>
            {title}
          </h3>
        )}
        {description && (
          <p style={{ color: 'var(--kn-text-muted)', fontSize: 'var(--text-sm)', textAlign: 'center', marginBottom: 28, lineHeight: 'var(--leading-tight)' }}>
            {description}
          </p>
        )}
        {children}
      </div>
    </div>
  );
}
