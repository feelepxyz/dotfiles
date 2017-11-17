#!/bin/bash

# Install latest node
nodenv install --list
nodenv install 9.1.0
nodenv global 9.1.0
nodenv rehash

npm update -g
