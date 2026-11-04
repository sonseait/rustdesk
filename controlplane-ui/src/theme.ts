import { createTheme } from '@mantine/core'

export const theme = createTheme({
  primaryColor: 'terracotta',
  autoContrast: true,
  primaryShade: { light: 7, dark: 3 },
  colors: {
    terracotta: ['#fff4ed', '#fbe5d8', '#f2c8b3', '#ffb294', '#da916f', '#c77451', '#b55c3b', '#a24c31', '#873e29', '#6f3328'],
    dark: ['#f6e9e2', '#dac6bc', '#b9a096', '#8e7368', '#71483b', '#493128', '#32221c', '#261b17', '#201613', '#181210'],
  },
  fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
  fontSizes: { xs: '0.75rem', sm: '0.8125rem', md: '0.875rem', lg: '1rem', xl: '1.125rem' },
  headings: {
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
    fontWeight: '700',
    sizes: { h1: { fontSize: '1.75rem', lineHeight: '1.2' }, h2: { fontSize: '1.125rem', lineHeight: '1.4' }, h3: { fontSize: '1rem', lineHeight: '1.4' } },
  },
  defaultRadius: 'md',
  radius: { xs: '6px', sm: '8px', md: '10px', lg: '15px', xl: '18px' },
  components: {
    Button: { defaultProps: { size: 'sm', fw: 600 } },
    ActionIcon: { defaultProps: { size: 'lg', variant: 'default', radius: 'md' } },
    Card: { defaultProps: { radius: 'lg', padding: 'lg' } },
    Paper: { defaultProps: { radius: 'lg' } },
    Badge: { defaultProps: { variant: 'light', radius: 'sm', size: 'sm' } },
    Drawer: { defaultProps: { closeButtonProps: { 'aria-label': 'Close navigation' } } },
    Modal: { defaultProps: { closeButtonProps: { 'aria-label': 'Close dialog' }, radius: 'xl', padding: 'xl', overlayProps: { backgroundOpacity: 0.3, blur: 6 } } },
    TextInput: { defaultProps: { size: 'sm' } },
    NumberInput: { defaultProps: { size: 'sm' } },
    PasswordInput: { defaultProps: { size: 'sm' } },
    NavLink: { defaultProps: { variant: 'light' } },
  },
})
