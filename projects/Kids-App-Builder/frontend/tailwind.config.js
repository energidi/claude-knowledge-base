/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        coral: '#F15048',
        purple: {
          brand: '#6C63FF'
        },
        success: '#2ECC71',
        bg: '#F8F9FA',
        text: {
          primary: '#2D2D2D',
          secondary: '#777777'
        }
      },
      fontFamily: {
        sans: ['Nunito', 'sans-serif']
      }
    }
  },
  plugins: []
}
