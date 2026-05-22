async function deleteAllFiles() {
  const deleteButtons = document.querySelectorAll('button.codeide-file-delete-action.delete');
  
  console.log(`Found ${deleteButtons.length} files to delete...`);
  
  for (const btn of deleteButtons) {
    const url = btn.dataset.url;
    const headers = JSON.parse(btn.dataset.headers);
    const filename = url.split('/').pop();
    
    try {
      const response = await fetch(url, {
        method: 'DELETE',
        headers: headers
      });
      
      if (response.ok) {
        console.log(`Deleted: ${filename}`);
      } else {
        console.warn(`Failed to delete ${filename}: HTTP ${response.status}`);
      }
    } catch (err) {
      console.error(`Error deleting ${filename}:`, err);
    }
  }
  
  console.log('Done! Reload the page to see the updated file list.');
}

deleteAllFiles();
