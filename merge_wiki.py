import os
import glob

# The order here determines the order of chapters in your PDF
sections = [
    'README.md',       # Usually makes sense to have the root README as the intro
    'architecture',
    'guides',
    'modules',
    'technical'
]

output_filename = 'compiled_wiki.md'
page_break = '\n\n<div style="page-break-after: always;"></div>\n\n'

with open(output_filename, 'w', encoding='utf-8') as outfile:
    for section in sections:
        # If the section is a direct file (like README.md)
        if section.endswith('.md'):
            if os.path.exists(section):
                with open(section, 'r', encoding='utf-8') as infile:
                    outfile.write(infile.read() + page_break)
        
        # If the section is a folder, grab all .md files inside it
        else:
            # Sort alphabetically so the files append in a predictable order
            files = sorted(glob.glob(f"{section}/*.md"))
            for filepath in files:
                with open(filepath, 'r', encoding='utf-8') as infile:
                    outfile.write(infile.read() + page_break)

print(f"✅ Successfully merged all files into {output_filename}")