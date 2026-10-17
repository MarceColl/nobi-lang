The single modal pattern — a blurred void backdrop and a 440px panel with centered Fraunces title.

```jsx
<Dialog title="Get early access" description="Join the waitlist." onClose={close}>
  <Input type="email" placeholder="Enter your email" />
</Dialog>
```

Title and description are centered; the body below them is not. Actions go full-width and square.
