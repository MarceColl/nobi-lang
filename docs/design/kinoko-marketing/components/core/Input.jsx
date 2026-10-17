import React, { useState } from 'react';

export function Input({ type = 'text', invalid = false, style, ...rest }) {
  const [focused, setFocused] = useState(false);
  return (
    <input
      type={type}
      onFocus={(e) => { setFocused(true); rest.onFocus && rest.onFocus(e); }}
      onBlur={(e) => { setFocused(false); rest.onBlur && rest.onBlur(e); }}
      style={{
        padding: '16px 20px',
        width: '100%',
        background: 'rgba(10, 8, 15, 0.8)',
        border: `1px solid ${invalid ? 'var(--kn-red)' : focused ? 'var(--kn-mint)' : 'var(--kn-border-violet-strong)'}`,
        borderRadius: 'var(--radius-lg)',
        fontSize: 'var(--text-base)',
        fontFamily: 'var(--font-body)',
        color: 'var(--kn-text)',
        outline: 'none',
        transition: 'border-color var(--dur-fast) var(--ease)',
        ...style,
      }}
      {...rest}
    />
  );
}
