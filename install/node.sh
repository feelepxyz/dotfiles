#!/bin/bash

# Install latest node
nodenv install --list
nodenv install 11.3.0
nodenv global 11.3.0
nodenv rehash

npm update -g
