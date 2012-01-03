# -*- coding: utf-8 -*-

import sys, os

needs_sphinx = '1.1.2'

extensions = []

templates_path = ['_templates']

source_suffix = '.rst'

source_encoding = 'utf-8-sig'

master_doc = 'index'

project = u'Cosmic'
copyright = u'2012, Ning'

version = '0.0.1-SNAPSHOT'
release = '0.0.1-SNAPSHOT'

exclude_trees = ['.build']

add_function_parentheses = True

pygments_style = 'trac'

master_doc = 'index'

# -- Options for HTML output ---------------------------------------------------

html_theme = 'cosmic'

html_theme_path = ["_theme"]

html_static_path = ['_static']

html_use_smartypants = True

html_use_index = True

htmlhelp_basename = 'cosmicdoc'

html_sidebars = {
    'index': ['globaltoc.html', 'relations.html', 'sidebarintro.html', 'searchbox.html'],
    '**': ['globaltoc.html', 'relations.html', 'sidebarintro.html', 'searchbox.html']
}