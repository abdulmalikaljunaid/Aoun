/* ════════════════════════════════════════════════════════════════
   Aoun (عون) — Landing Page Scripts (Accordion & Interactions)
   ════════════════════════════════════════════════════════════════ */

document.addEventListener('DOMContentLoaded', () => {
    // 1. FAQ Accordion Toggle Logic
    const faqHeaders = document.querySelectorAll('.faq-header');

    faqHeaders.forEach(header => {
        header.addEventListener('click', () => {
            const card = header.closest('.faq-card');
            const isExpanded = header.getAttribute('aria-expanded') === 'true';

            // Close all open cards for clean accordion behavior
            document.querySelectorAll('.faq-card').forEach(otherCard => {
                if (otherCard !== card) {
                    otherCard.classList.remove('open');
                    const otherHeader = otherCard.querySelector('.faq-header');
                    if (otherHeader) otherHeader.setAttribute('aria-expanded', 'false');
                }
            });

            // Toggle current card
            if (isExpanded) {
                header.setAttribute('aria-expanded', 'false');
                card.classList.remove('open');
            } else {
                header.setAttribute('aria-expanded', 'true');
                card.classList.add('open');
            }
        });
    });

    // 2. Smooth Navbar Scroll & Glass Elevation
    const navbar = document.getElementById('navbar');
    window.addEventListener('scroll', () => {
        if (window.scrollY > 40) {
            navbar.style.boxShadow = '0 10px 30px rgba(0, 0, 0, 0.4)';
        } else {
            navbar.style.boxShadow = 'none';
        }
    });

    console.log('عون | Aoun Landing Page initialized smoothly.');
});
