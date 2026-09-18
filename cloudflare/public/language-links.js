document.addEventListener('click',event=>{const link=event.target.closest('a[data-language]');if(link)try{localStorage.setItem('aqb-lang',link.dataset.language);}catch{}});
