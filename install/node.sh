#!/bin/bash

# Install latest node
nodenv install --list
nodenv install 12.0.0
nodenv global 12.0.0
nodenv rehash

npm update -g
